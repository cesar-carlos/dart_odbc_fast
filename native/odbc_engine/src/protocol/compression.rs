use crate::error::{OdbcError, Result};
use crate::protocol::columnar::CompressionType;
use std::borrow::Cow;
use std::io::Read;

const COMPRESSION_THRESHOLD_BYTES: usize = 1_000_000;
pub const DEFAULT_MAX_DECOMPRESSED_LEN: usize = 256 * 1024 * 1024;

#[derive(Clone, Copy, Debug)]
pub enum CompressionStrategy {
    None,
    Zstd(i32),
    Lz4,
}

impl CompressionStrategy {
    pub fn auto_select(payload_size: usize) -> Self {
        if payload_size > COMPRESSION_THRESHOLD_BYTES {
            Self::Zstd(3)
        } else {
            Self::None
        }
    }

    pub fn compress(&self, data: &[u8]) -> Result<Vec<u8>> {
        self.compress_cow(data).map(Cow::into_owned)
    }

    pub fn compress_cow<'a>(&self, data: &'a [u8]) -> Result<Cow<'a, [u8]>> {
        match self {
            Self::None => Ok(Cow::Borrowed(data)),
            Self::Zstd(level) => zstd::encode_all(data, *level)
                .map(Cow::Owned)
                .map_err(|e| OdbcError::InternalError(format!("Zstd compression failed: {}", e))),
            Self::Lz4 => {
                let ct = CompressionType::Lz4;
                compress(data, ct).map(Cow::Owned)
            }
        }
    }

    pub fn compress_owned(&self, data: Vec<u8>) -> Result<Vec<u8>> {
        match self {
            Self::None => Ok(data),
            Self::Zstd(level) => zstd::encode_all(&data[..], *level)
                .map_err(|e| OdbcError::InternalError(format!("Zstd compression failed: {}", e))),
            Self::Lz4 => compress(&data, CompressionType::Lz4),
        }
    }
}

pub fn compress(data: &[u8], compression_type: CompressionType) -> Result<Vec<u8>> {
    compress_cow(data, compression_type).map(Cow::into_owned)
}

pub fn compress_cow(data: &[u8], compression_type: CompressionType) -> Result<Cow<'_, [u8]>> {
    match compression_type {
        CompressionType::None => Ok(Cow::Borrowed(data)),
        CompressionType::Zstd => zstd::encode_all(data, 3)
            .map(Cow::Owned)
            .map_err(|e| OdbcError::InternalError(format!("Zstd compression failed: {}", e))),
        CompressionType::Lz4 => {
            let mut encoder = lz4::EncoderBuilder::new()
                .level(4)
                .build(Vec::new())
                .map_err(|e| {
                    OdbcError::InternalError(format!("Lz4 encoder creation failed: {}", e))
                })?;

            use std::io::Write;
            encoder
                .write_all(data)
                .map_err(|e| OdbcError::InternalError(format!("Lz4 write failed: {}", e)))?;

            let (compressed, result) = encoder.finish();
            result.map_err(|e| OdbcError::InternalError(format!("Lz4 finish failed: {}", e)))?;
            Ok(Cow::Owned(compressed))
        }
    }
}

pub fn decompress(data: &[u8], compression_type: CompressionType) -> Result<Vec<u8>> {
    decompress_with_limit(data, compression_type, DEFAULT_MAX_DECOMPRESSED_LEN)
}

pub fn decompress_cow(data: &[u8], compression_type: CompressionType) -> Result<Cow<'_, [u8]>> {
    decompress_cow_with_limit(data, compression_type, DEFAULT_MAX_DECOMPRESSED_LEN)
}

pub fn decompress_with_limit(
    data: &[u8],
    compression_type: CompressionType,
    max_decompressed_len: usize,
) -> Result<Vec<u8>> {
    decompress_cow_with_limit(data, compression_type, max_decompressed_len).map(Cow::into_owned)
}

pub fn decompress_cow_with_limit(
    data: &[u8],
    compression_type: CompressionType,
    max_decompressed_len: usize,
) -> Result<Cow<'_, [u8]>> {
    match compression_type {
        CompressionType::None => {
            if data.len() > max_decompressed_len {
                return Err(decompression_limit_error(data.len(), max_decompressed_len));
            }
            Ok(Cow::Borrowed(data))
        }
        CompressionType::Zstd => {
            let decoder = zstd::Decoder::new(data).map_err(|e| {
                OdbcError::InternalError(format!("Zstd decoder creation failed: {}", e))
            })?;
            read_limited(decoder, max_decompressed_len).map(Cow::Owned)
        }
        CompressionType::Lz4 => {
            let mut decoder = lz4::Decoder::new(data).map_err(|e| {
                OdbcError::InternalError(format!("Lz4 decoder creation failed: {}", e))
            })?;

            read_limited(&mut decoder, max_decompressed_len).map(Cow::Owned)
        }
    }
}

fn read_limited<R: Read>(reader: R, max_decompressed_len: usize) -> Result<Vec<u8>> {
    let limit = max_decompressed_len.checked_add(1).ok_or_else(|| {
        OdbcError::ResourceLimitReached("Decompression limit overflow".to_string())
    })?;
    let mut limited = reader.take(limit as u64);
    let mut decompressed = Vec::new();
    limited
        .read_to_end(&mut decompressed)
        .map_err(|e| OdbcError::InternalError(format!("Decompression read failed: {}", e)))?;
    if decompressed.len() > max_decompressed_len {
        return Err(decompression_limit_error(
            decompressed.len(),
            max_decompressed_len,
        ));
    }
    Ok(decompressed)
}

fn decompression_limit_error(actual: usize, limit: usize) -> OdbcError {
    OdbcError::ResourceLimitReached(format!(
        "Decompressed payload length {} exceeds limit {}",
        actual, limit
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compress_none() {
        let data = b"test data";
        let result = compress(data, CompressionType::None);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), data);
    }

    #[test]
    fn test_compress_none_borrows_input() {
        let data = b"test data";
        let result = compress_cow(data, CompressionType::None).unwrap();
        assert!(matches!(result, Cow::Borrowed(_)));
        assert_eq!(result.as_ref(), data);
    }

    #[test]
    fn test_decompress_none() {
        let data = b"test data";
        let result = decompress(data, CompressionType::None);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), data);
    }

    #[test]
    fn test_decompress_none_borrows_input() {
        let data = b"test data";
        let result = decompress_cow(data, CompressionType::None).unwrap();
        assert!(matches!(result, Cow::Borrowed(_)));
        assert_eq!(result.as_ref(), data);
    }

    #[test]
    fn test_decompress_none_respects_limit() {
        let data = b"test data";
        let result = decompress_with_limit(data, CompressionType::None, data.len() - 1);
        assert!(matches!(result, Err(OdbcError::ResourceLimitReached(_))));
    }

    #[test]
    fn test_compress_zstd() {
        let data = b"test data for zstd compression";
        let result = compress(data, CompressionType::Zstd);
        assert!(result.is_ok());
        let compressed = result.unwrap();
        assert!(!compressed.is_empty());
        assert_ne!(compressed, data);
    }

    #[test]
    fn test_decompress_zstd() {
        let original = b"test data for zstd compression";
        let compressed = compress(original, CompressionType::Zstd).unwrap();
        let decompressed = decompress(&compressed, CompressionType::Zstd);
        assert!(decompressed.is_ok());
        assert_eq!(decompressed.unwrap(), original);
    }

    #[test]
    fn test_compress_lz4() {
        let data = b"test data for lz4 compression";
        let result = compress(data, CompressionType::Lz4);
        assert!(result.is_ok());
        let compressed = result.unwrap();
        assert!(!compressed.is_empty());
        assert_ne!(compressed, data);
    }

    #[test]
    fn test_decompress_lz4() {
        let original = b"test data for lz4 compression";
        let compressed = compress(original, CompressionType::Lz4).unwrap();
        let decompressed = decompress(&compressed, CompressionType::Lz4);
        assert!(decompressed.is_ok());
        assert_eq!(decompressed.unwrap(), original);
    }

    #[test]
    fn test_compress_empty_data() {
        let data = b"";
        let result_zstd = compress(data, CompressionType::Zstd);
        assert!(result_zstd.is_ok());

        let result_lz4 = compress(data, CompressionType::Lz4);
        assert!(result_lz4.is_ok());
    }

    #[test]
    fn test_compress_large_data() {
        let data = vec![0u8; 10000];
        let result_zstd = compress(&data, CompressionType::Zstd);
        assert!(result_zstd.is_ok());

        let result_lz4 = compress(&data, CompressionType::Lz4);
        assert!(result_lz4.is_ok());
    }

    #[test]
    fn test_roundtrip_zstd() {
        let original = b"roundtrip test data for zstd";
        let compressed = compress(original, CompressionType::Zstd).unwrap();
        let decompressed = decompress(&compressed, CompressionType::Zstd).unwrap();
        assert_eq!(decompressed, original);
    }

    #[test]
    fn test_roundtrip_lz4() {
        let original = b"roundtrip test data for lz4";
        let compressed = compress(original, CompressionType::Lz4).unwrap();
        let decompressed = decompress(&compressed, CompressionType::Lz4).unwrap();
        assert_eq!(decompressed, original);
    }

    #[test]
    fn test_decompress_zstd_respects_limit() {
        let original = b"roundtrip test data for zstd";
        let compressed = compress(original, CompressionType::Zstd).unwrap();
        let result = decompress_with_limit(&compressed, CompressionType::Zstd, original.len() - 1);
        assert!(matches!(result, Err(OdbcError::ResourceLimitReached(_))));
    }

    #[test]
    fn test_compression_strategy_auto_select_small() {
        let s = CompressionStrategy::auto_select(100);
        assert!(matches!(s, CompressionStrategy::None));
    }

    #[test]
    fn test_compression_strategy_auto_select_large() {
        let s = CompressionStrategy::auto_select(2_000_000);
        assert!(matches!(s, CompressionStrategy::Zstd(3)));
    }

    #[test]
    fn test_compression_strategy_compress_none() {
        let s = CompressionStrategy::None;
        let data = b"hello";
        let out = s.compress(data).unwrap();
        assert_eq!(out, data);
    }

    #[test]
    fn test_compression_strategy_compress_owned_none_reuses_input() {
        let s = CompressionStrategy::None;
        let data = b"hello".to_vec();
        let ptr = data.as_ptr();
        let out = s.compress_owned(data).unwrap();
        assert_eq!(out, b"hello");
        assert_eq!(out.as_ptr(), ptr);
    }

    #[test]
    fn test_compression_strategy_compress_zstd() {
        let s = CompressionStrategy::Zstd(1);
        let data = b"hello world";
        let out = s.compress(data).unwrap();
        assert!(!out.is_empty());
        assert_ne!(out, data);
    }
}

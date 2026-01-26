use crate::error::{OdbcError, Result};
use crate::protocol::columnar::CompressionType;

const COMPRESSION_THRESHOLD_BYTES: usize = 1_000_000;

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
        match self {
            Self::None => Ok(data.to_vec()),
            Self::Zstd(level) => zstd::encode_all(data, *level)
                .map_err(|e| OdbcError::InternalError(format!("Zstd compression failed: {}", e))),
            Self::Lz4 => {
                let ct = CompressionType::Lz4;
                compress(data, ct)
            }
        }
    }
}

pub fn compress(data: &[u8], compression_type: CompressionType) -> Result<Vec<u8>> {
    match compression_type {
        CompressionType::None => Ok(data.to_vec()),
        CompressionType::Zstd => zstd::encode_all(data, 3)
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
            Ok(compressed)
        }
    }
}

pub fn decompress(data: &[u8], compression_type: CompressionType) -> Result<Vec<u8>> {
    match compression_type {
        CompressionType::None => Ok(data.to_vec()),
        CompressionType::Zstd => zstd::decode_all(data)
            .map_err(|e| OdbcError::InternalError(format!("Zstd decompression failed: {}", e))),
        CompressionType::Lz4 => {
            let mut decoder = lz4::Decoder::new(data).map_err(|e| {
                OdbcError::InternalError(format!("Lz4 decoder creation failed: {}", e))
            })?;

            use std::io::Read;
            let mut decompressed = Vec::new();
            decoder
                .read_to_end(&mut decompressed)
                .map_err(|e| OdbcError::InternalError(format!("Lz4 read failed: {}", e)))?;
            Ok(decompressed)
        }
    }
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
    fn test_decompress_none() {
        let data = b"test data";
        let result = decompress(data, CompressionType::None);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), data);
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
    fn test_compression_strategy_compress_zstd() {
        let s = CompressionStrategy::Zstd(1);
        let data = b"hello world";
        let out = s.compress(data).unwrap();
        assert!(!out.is_empty());
        assert_ne!(out, data);
    }
}

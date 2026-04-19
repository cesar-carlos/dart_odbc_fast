//! Multi-result set wire protocol.
//!
//! v1 (legacy):  `[count: u32 LE] [item ...]`
//!
//! v2 (current): `[magic: 0x4D554C54 ("MULT") LE]
//!                [version: u16 LE = 2] [reserved: u16 = 0]
//!                [count: u32 LE] [item ...]`
//!
//! Each `item` is identical in v1 and v2:
//! - `[tag: u8]` (0 = ResultSet, 1 = RowCount)
//! - `[len: u32 LE]`
//! - `[payload: len bytes]`
//!   * tag = 0 → payload is a row-buffer encoded by `binary_protocol` v1
//!   * tag = 1 → payload is `[i64 LE]` (8 bytes, signed row count)
//!
//! [`encode_multi`] always emits the v2 framing. [`decode_multi`] auto-detects
//! the framing by sniffing the first 4 bytes — payloads produced by older
//! versions of this engine continue to round-trip without a breaking change
//! at the FFI layer.

use crate::error::{OdbcError, Result};

const TAG_RESULT_SET: u8 = 0;
const TAG_ROW_COUNT: u8 = 1;

/// `MULT` little-endian (`b'M' | b'U'<<8 | b'L'<<16 | b'T'<<24`).
pub const MULTI_RESULT_MAGIC: u32 = 0x544C554D;

/// Current multi-result protocol version.
pub const MULTI_RESULT_VERSION: u16 = 2;

const HEADER_V2_LEN: usize = 4 /*magic*/ + 2 /*version*/ + 2 /*reserved*/ + 4 /*count*/;

#[derive(Debug, Clone, PartialEq)]
pub enum MultiResultItem {
    ResultSet(Vec<u8>),
    RowCount(i64),
}

/// Encode a list of items using the v2 framing (magic + version + count).
pub fn encode_multi(items: &[MultiResultItem]) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER_V2_LEN + estimate_payload_size(items));
    out.extend_from_slice(&MULTI_RESULT_MAGIC.to_le_bytes());
    out.extend_from_slice(&MULTI_RESULT_VERSION.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // reserved
    out.extend_from_slice(&(items.len() as u32).to_le_bytes());
    encode_items(items, &mut out);
    out
}

/// Encode using the legacy v1 framing (no magic, no version). Kept around for
/// regression / compatibility tests; production callers should use
/// [`encode_multi`].
#[doc(hidden)]
pub fn encode_multi_v1(items: &[MultiResultItem]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + estimate_payload_size(items));
    out.extend_from_slice(&(items.len() as u32).to_le_bytes());
    encode_items(items, &mut out);
    out
}

fn encode_items(items: &[MultiResultItem], out: &mut Vec<u8>) {
    for item in items {
        match item {
            MultiResultItem::ResultSet(buf) => {
                out.push(TAG_RESULT_SET);
                out.extend_from_slice(&(buf.len() as u32).to_le_bytes());
                out.extend_from_slice(buf);
            }
            MultiResultItem::RowCount(n) => {
                out.push(TAG_ROW_COUNT);
                out.extend_from_slice(&8u32.to_le_bytes());
                out.extend_from_slice(&n.to_le_bytes());
            }
        }
    }
}

fn estimate_payload_size(items: &[MultiResultItem]) -> usize {
    items
        .iter()
        .map(|i| match i {
            MultiResultItem::ResultSet(b) => 1 + 4 + b.len(),
            MultiResultItem::RowCount(_) => 1 + 4 + 8,
        })
        .sum()
}

/// Decode a multi-result buffer. Accepts both the v2 framing (magic +
/// version + count) and the legacy v1 framing (just `count`). Unknown
/// versions return `ValidationError`.
pub fn decode_multi(data: &[u8]) -> Result<Vec<MultiResultItem>> {
    if data.len() >= 4
        && u32::from_le_bytes([data[0], data[1], data[2], data[3]]) == MULTI_RESULT_MAGIC
    {
        decode_multi_v2(data)
    } else {
        decode_multi_v1(data)
    }
}

fn decode_multi_v2(data: &[u8]) -> Result<Vec<MultiResultItem>> {
    if data.len() < HEADER_V2_LEN {
        return Err(OdbcError::ValidationError(
            "Multi-result v2 buffer too short for header".to_string(),
        ));
    }
    let version = u16::from_le_bytes([data[4], data[5]]);
    if version != MULTI_RESULT_VERSION {
        return Err(OdbcError::ValidationError(format!(
            "Unsupported multi-result version: {} (expected {})",
            version, MULTI_RESULT_VERSION
        )));
    }
    let count = u32::from_le_bytes([data[8], data[9], data[10], data[11]]) as usize;
    decode_items(data, HEADER_V2_LEN, count)
}

fn decode_multi_v1(data: &[u8]) -> Result<Vec<MultiResultItem>> {
    if data.len() < 4 {
        return Err(OdbcError::ValidationError(
            "Multi-result buffer too short for count".to_string(),
        ));
    }
    let count = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    decode_items(data, 4, count)
}

fn decode_items(data: &[u8], mut offset: usize, count: usize) -> Result<Vec<MultiResultItem>> {
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        if offset >= data.len() {
            return Err(OdbcError::ValidationError(
                "Multi-result buffer truncated at item".to_string(),
            ));
        }
        let tag = data[offset];
        offset += 1;
        if offset + 4 > data.len() {
            return Err(OdbcError::ValidationError(
                "Multi-result buffer truncated at item length".to_string(),
            ));
        }
        let len = u32::from_le_bytes([
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ]) as usize;
        offset += 4;
        if offset + len > data.len() {
            return Err(OdbcError::ValidationError(
                "Multi-result buffer truncated at item payload".to_string(),
            ));
        }
        let payload = &data[offset..offset + len];
        offset += len;
        match tag {
            TAG_RESULT_SET => out.push(MultiResultItem::ResultSet(payload.to_vec())),
            TAG_ROW_COUNT => {
                if len != 8 {
                    return Err(OdbcError::ValidationError(
                        "RowCount item expected 8-byte payload".to_string(),
                    ));
                }
                let n = i64::from_le_bytes([
                    payload[0], payload[1], payload[2], payload[3], payload[4], payload[5],
                    payload[6], payload[7],
                ]);
                out.push(MultiResultItem::RowCount(n));
            }
            _ => {
                return Err(OdbcError::ValidationError(format!(
                    "Unknown multi-result item tag: {}",
                    tag
                )));
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_decode_multi_empty() {
        let items: Vec<MultiResultItem> = vec![];
        let enc = encode_multi(&items);
        let dec = decode_multi(&enc).unwrap();
        assert_eq!(dec, items);
    }

    #[test]
    fn test_encode_decode_multi_row_count() {
        let items = vec![MultiResultItem::RowCount(42)];
        let enc = encode_multi(&items);
        let dec = decode_multi(&enc).unwrap();
        assert_eq!(dec, items);
    }

    #[test]
    fn test_encode_decode_multi_result_set() {
        let items = vec![MultiResultItem::ResultSet(vec![1, 2, 3])];
        let enc = encode_multi(&items);
        let dec = decode_multi(&enc).unwrap();
        assert_eq!(dec, items);
    }

    #[test]
    fn test_encode_decode_multi_mixed() {
        let items = vec![
            MultiResultItem::ResultSet(vec![10, 20]),
            MultiResultItem::RowCount(7),
            MultiResultItem::ResultSet(vec![30]),
        ];
        let enc = encode_multi(&items);
        let dec = decode_multi(&enc).unwrap();
        assert_eq!(dec, items);
    }

    #[test]
    fn test_decode_multi_too_short() {
        let r = decode_multi(&[0, 0]);
        assert!(r.is_err());
    }

    #[test]
    fn encode_multi_emits_v2_header_with_magic_and_version() {
        let bytes = encode_multi(&[]);
        assert!(bytes.len() >= HEADER_V2_LEN);
        let magic = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        let version = u16::from_le_bytes([bytes[4], bytes[5]]);
        let reserved = u16::from_le_bytes([bytes[6], bytes[7]]);
        let count = u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]);
        assert_eq!(magic, MULTI_RESULT_MAGIC);
        assert_eq!(version, MULTI_RESULT_VERSION);
        assert_eq!(reserved, 0);
        assert_eq!(count, 0);
    }

    #[test]
    fn decode_multi_accepts_v1_legacy_payload() {
        let items = vec![
            MultiResultItem::ResultSet(vec![10, 20]),
            MultiResultItem::RowCount(7),
        ];
        let v1 = encode_multi_v1(&items);
        let dec = decode_multi(&v1).expect("legacy v1 buffer must decode");
        assert_eq!(dec, items);
    }

    #[test]
    fn decode_multi_rejects_unknown_version() {
        let mut bytes = encode_multi(&[]);
        // Flip version to something we don't understand.
        bytes[4] = 99;
        bytes[5] = 0;
        let r = decode_multi(&bytes);
        assert!(matches!(r, Err(OdbcError::ValidationError(_))));
    }

    #[test]
    fn decode_multi_v2_truncated_header_returns_error() {
        let bytes: Vec<u8> = MULTI_RESULT_MAGIC.to_le_bytes().to_vec();
        // Not enough bytes for version/reserved/count.
        assert!(matches!(
            decode_multi(&bytes),
            Err(OdbcError::ValidationError(_))
        ));
    }
}

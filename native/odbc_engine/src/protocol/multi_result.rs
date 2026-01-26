use crate::error::{OdbcError, Result};

const TAG_RESULT_SET: u8 = 0;
const TAG_ROW_COUNT: u8 = 1;

#[derive(Debug, Clone, PartialEq)]
pub enum MultiResultItem {
    ResultSet(Vec<u8>),
    RowCount(i64),
}

pub fn encode_multi(items: &[MultiResultItem]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(items.len() as u32).to_le_bytes());
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
    out
}

pub fn decode_multi(data: &[u8]) -> Result<Vec<MultiResultItem>> {
    if data.len() < 4 {
        return Err(OdbcError::ValidationError(
            "Multi-result buffer too short for count".to_string(),
        ));
    }
    let count = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let mut out = Vec::with_capacity(count);
    let mut offset = 4;
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
}

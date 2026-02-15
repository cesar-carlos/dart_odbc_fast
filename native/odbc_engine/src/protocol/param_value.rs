use crate::error::{OdbcError, Result};

const TAG_NULL: u8 = 0;
const TAG_STRING: u8 = 1;
const TAG_INTEGER: u8 = 2;
const TAG_BIGINT: u8 = 3;
const TAG_DECIMAL: u8 = 4;
const TAG_BINARY: u8 = 5;

#[derive(Debug, Clone, PartialEq)]
pub enum ParamValue {
    String(String),
    Integer(i32),
    BigInt(i64),
    Decimal(String),
    Binary(Vec<u8>),
    Null,
}

impl ParamValue {
    pub fn serialize(&self) -> Vec<u8> {
        let mut out = Vec::new();
        match self {
            ParamValue::Null => {
                out.push(TAG_NULL);
                out.extend_from_slice(&0u32.to_le_bytes());
            }
            ParamValue::String(s) => {
                out.push(TAG_STRING);
                let b = s.as_bytes();
                out.extend_from_slice(&(b.len() as u32).to_le_bytes());
                out.extend_from_slice(b);
            }
            ParamValue::Integer(n) => {
                out.push(TAG_INTEGER);
                out.extend_from_slice(&4u32.to_le_bytes());
                out.extend_from_slice(&n.to_le_bytes());
            }
            ParamValue::BigInt(n) => {
                out.push(TAG_BIGINT);
                out.extend_from_slice(&8u32.to_le_bytes());
                out.extend_from_slice(&n.to_le_bytes());
            }
            ParamValue::Decimal(s) => {
                out.push(TAG_DECIMAL);
                let b = s.as_bytes();
                out.extend_from_slice(&(b.len() as u32).to_le_bytes());
                out.extend_from_slice(b);
            }
            ParamValue::Binary(b) => {
                out.push(TAG_BINARY);
                out.extend_from_slice(&(b.len() as u32).to_le_bytes());
                out.extend_from_slice(b);
            }
        }
        out
    }

    pub fn deserialize(data: &[u8]) -> Result<(Self, usize)> {
        if data.len() < 5 {
            return Err(OdbcError::ValidationError(
                "ParamValue buffer too short".to_string(),
            ));
        }
        let tag = data[0];
        let len = u32::from_le_bytes([data[1], data[2], data[3], data[4]]) as usize;
        let consumed = 5usize.saturating_add(len);

        if data.len() < consumed {
            return Err(OdbcError::ValidationError(
                "ParamValue buffer truncated".to_string(),
            ));
        }

        let payload = if len > 0 { &data[5..consumed] } else { &[] };

        let p = match tag {
            TAG_NULL => ParamValue::Null,
            TAG_STRING => {
                let s = std::str::from_utf8(payload).map_err(|_| {
                    OdbcError::ValidationError("Invalid UTF-8 in ParamValue::String".to_string())
                })?;
                ParamValue::String(s.to_string())
            }
            TAG_INTEGER => {
                if len != 4 {
                    return Err(OdbcError::ValidationError(
                        "ParamValue::Integer expected 4 bytes".to_string(),
                    ));
                }
                ParamValue::Integer(i32::from_le_bytes([
                    payload[0], payload[1], payload[2], payload[3],
                ]))
            }
            TAG_BIGINT => {
                if len != 8 {
                    return Err(OdbcError::ValidationError(
                        "ParamValue::BigInt expected 8 bytes".to_string(),
                    ));
                }
                ParamValue::BigInt(i64::from_le_bytes([
                    payload[0], payload[1], payload[2], payload[3], payload[4], payload[5],
                    payload[6], payload[7],
                ]))
            }
            TAG_DECIMAL => {
                let s = std::str::from_utf8(payload).map_err(|_| {
                    OdbcError::ValidationError("Invalid UTF-8 in ParamValue::Decimal".to_string())
                })?;
                ParamValue::Decimal(s.to_string())
            }
            TAG_BINARY => ParamValue::Binary(payload.to_vec()),
            _ => {
                return Err(OdbcError::ValidationError(format!(
                    "Unknown ParamValue tag: {}",
                    tag
                )))
            }
        };

        Ok((p, consumed))
    }
}

pub fn deserialize_params(data: &[u8]) -> Result<Vec<ParamValue>> {
    let mut out = Vec::new();
    let mut offset = 0;
    while offset < data.len() {
        let (p, n) = ParamValue::deserialize(&data[offset..])?;
        out.push(p);
        offset += n;
    }
    Ok(out)
}

pub fn serialize_params(params: &[ParamValue]) -> Vec<u8> {
    let mut out = Vec::new();
    for p in params {
        out.extend(p.serialize());
    }
    out
}

pub fn param_values_to_strings(params: &[ParamValue]) -> Result<Vec<Option<String>>> {
    let mut out = Vec::with_capacity(params.len());
    for p in params {
        match p {
            ParamValue::Null => out.push(None),
            ParamValue::String(s) => out.push(Some(s.clone())),
            ParamValue::Integer(n) => out.push(Some(n.to_string())),
            ParamValue::BigInt(n) => out.push(Some(n.to_string())),
            ParamValue::Decimal(s) => out.push(Some(s.clone())),
            ParamValue::Binary(b) => {
                out.push(Some(
                    b.iter().map(|x| format!("{:02x}", x)).collect::<String>(),
                ));
            }
        }
    }
    Ok(out)
}

pub fn has_null_param(params: &[ParamValue]) -> bool {
    params.iter().any(|p| matches!(p, ParamValue::Null))
}

pub fn max_param_string_len(params: &[ParamValue]) -> usize {
    let mut max_len = 1;
    for p in params {
        let len = match p {
            ParamValue::String(s) => s.len(),
            ParamValue::Decimal(s) => s.len(),
            ParamValue::Binary(b) => b.len() * 2,
            _ => 0,
        };
        max_len = max_len.max(len);
    }
    max_len
}

pub fn param_count_exceeds_limit(params: &[ParamValue], limit: usize) -> bool {
    params.len() > limit
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_param_value_null_roundtrip() {
        let p = ParamValue::Null;
        let enc = p.serialize();
        let (dec, n) = ParamValue::deserialize(&enc).unwrap();
        assert_eq!(dec, ParamValue::Null);
        assert_eq!(n, enc.len());
    }

    #[test]
    fn test_param_value_string_roundtrip() {
        let p = ParamValue::String("hello".to_string());
        let enc = p.serialize();
        let (dec, n) = ParamValue::deserialize(&enc).unwrap();
        assert_eq!(dec, p);
        assert_eq!(n, enc.len());
    }

    #[test]
    fn test_param_value_integer_roundtrip() {
        let p = ParamValue::Integer(42);
        let enc = p.serialize();
        let (dec, n) = ParamValue::deserialize(&enc).unwrap();
        assert_eq!(dec, p);
        assert_eq!(n, enc.len());
    }

    #[test]
    fn test_param_value_bigint_roundtrip() {
        let p = ParamValue::BigInt(1234567890123456789i64);
        let enc = p.serialize();
        let (dec, n) = ParamValue::deserialize(&enc).unwrap();
        assert_eq!(dec, p);
        assert_eq!(n, enc.len());
    }

    #[test]
    fn test_param_value_decimal_roundtrip() {
        let p = ParamValue::Decimal("3.14159".to_string());
        let enc = p.serialize();
        let (dec, n) = ParamValue::deserialize(&enc).unwrap();
        assert_eq!(dec, p);
        assert_eq!(n, enc.len());
    }

    #[test]
    fn test_param_value_binary_roundtrip() {
        let p = ParamValue::Binary(vec![1, 2, 3, 0xff]);
        let enc = p.serialize();
        let (dec, n) = ParamValue::deserialize(&enc).unwrap();
        assert_eq!(dec, p);
        assert_eq!(n, enc.len());
    }

    #[test]
    fn test_deserialize_params_empty() {
        let out = deserialize_params(&[]).unwrap();
        assert!(out.is_empty());
    }

    #[test]
    fn test_serialize_deserialize_params_mixed() {
        let params = vec![
            ParamValue::Integer(1),
            ParamValue::String("a".to_string()),
            ParamValue::Null,
        ];
        let enc = serialize_params(&params);
        let dec = deserialize_params(&enc).unwrap();
        assert_eq!(dec, params);
    }

    #[test]
    fn test_deserialize_too_short() {
        let r = ParamValue::deserialize(&[0u8, 0, 0]);
        assert!(r.is_err());
    }

    #[test]
    fn test_has_null_param_no_null() {
        let params = vec![
            ParamValue::Integer(1),
            ParamValue::String("test".to_string()),
            ParamValue::BigInt(100),
        ];
        assert!(!has_null_param(&params));
    }

    #[test]
    fn test_has_null_param_with_null() {
        let params = vec![
            ParamValue::Integer(1),
            ParamValue::Null,
            ParamValue::String("test".to_string()),
        ];
        assert!(has_null_param(&params));
    }

    #[test]
    fn test_has_null_param_all_null() {
        let params = vec![ParamValue::Null, ParamValue::Null];
        assert!(has_null_param(&params));
    }

    #[test]
    fn test_has_null_param_empty() {
        let params = vec![];
        assert!(!has_null_param(&params));
    }

    #[test]
    fn test_param_count_exceeds_limit_true() {
        let params = vec![
            ParamValue::Integer(1),
            ParamValue::Integer(2),
            ParamValue::Integer(3),
        ];
        assert!(param_count_exceeds_limit(&params, 2));
    }

    #[test]
    fn test_param_count_exceeds_limit_false() {
        let params = vec![ParamValue::Integer(1), ParamValue::Integer(2)];
        assert!(!param_count_exceeds_limit(&params, 10));
    }

    #[test]
    fn test_param_count_exceeds_limit_equal() {
        let params = vec![ParamValue::Null, ParamValue::Null];
        assert!(!param_count_exceeds_limit(&params, 2));
    }

    #[test]
    fn test_max_param_string_len_empty() {
        let params = vec![];
        assert_eq!(max_param_string_len(&params), 1);
    }

    #[test]
    fn test_max_param_string_len_strings() {
        let params = vec![
            ParamValue::String("a".to_string()),
            ParamValue::String("abc".to_string()),
            ParamValue::String("ab".to_string()),
        ];
        assert_eq!(max_param_string_len(&params), 3);
    }

    #[test]
    fn test_max_param_string_len_decimal() {
        let params = vec![
            ParamValue::Decimal("1.5".to_string()),
            ParamValue::Decimal("12.345".to_string()),
        ];
        assert_eq!(max_param_string_len(&params), 6);
    }

    #[test]
    fn test_max_param_string_len_binary() {
        let params = vec![
            ParamValue::Binary(vec![1, 2]),
            ParamValue::Binary(vec![1, 2, 3, 4]),
        ];
        assert_eq!(max_param_string_len(&params), 8);
    }

    #[test]
    fn test_max_param_string_len_mixed() {
        let params = vec![
            ParamValue::Integer(42),
            ParamValue::String("hello world".to_string()),
            ParamValue::Binary(vec![1, 2, 3]),
        ];
        assert_eq!(max_param_string_len(&params), 11);
    }

    #[test]
    fn test_param_values_to_strings_with_null() {
        let params = vec![
            ParamValue::String("test".to_string()),
            ParamValue::Null,
            ParamValue::Integer(42),
        ];
        let result = param_values_to_strings(&params).unwrap();
        assert_eq!(result.len(), 3);
        assert_eq!(result[0], Some("test".to_string()));
        assert_eq!(result[1], None);
        assert_eq!(result[2], Some("42".to_string()));
    }

    #[test]
    fn test_param_values_to_strings_decimal_and_binary() {
        let params = vec![
            ParamValue::Decimal("3.14".to_string()),
            ParamValue::Binary(vec![0xab, 0xcd]),
        ];
        let result = param_values_to_strings(&params).unwrap();
        assert_eq!(result.len(), 2);
        assert_eq!(result[0], Some("3.14".to_string()));
        assert_eq!(result[1], Some("abcd".to_string()));
    }

    #[test]
    fn test_deserialize_buffer_truncated() {
        let enc = ParamValue::String("hello".to_string()).serialize();
        let truncated = &enc[0..enc.len() - 2];
        let result = ParamValue::deserialize(truncated);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("truncated"));
    }

    #[test]
    fn test_deserialize_invalid_utf8_string() {
        let mut data = vec![TAG_STRING, 0, 0, 0, 2];
        data.extend_from_slice(&[0xFF, 0xFE]);
        let result = ParamValue::deserialize(&data);
        assert!(result.is_err());
    }

    #[test]
    fn test_deserialize_integer_wrong_length() {
        let mut data = vec![TAG_INTEGER, 0, 0, 0, 2];
        data.extend_from_slice(&[1, 2]);
        let result = ParamValue::deserialize(&data);
        assert!(result.is_err());
    }

    #[test]
    fn test_deserialize_bigint_wrong_length() {
        let mut data = vec![TAG_BIGINT, 0, 0, 0, 4];
        data.extend_from_slice(&[1, 2, 3, 4]);
        let result = ParamValue::deserialize(&data);
        assert!(result.is_err());
    }

    #[test]
    fn test_deserialize_invalid_utf8_decimal() {
        let mut data = vec![TAG_DECIMAL, 0, 0, 0, 2];
        data.extend_from_slice(&[0x80, 0xFF]);
        let result = ParamValue::deserialize(&data);
        assert!(result.is_err());
    }

    #[test]
    fn test_deserialize_unknown_tag() {
        let data = vec![0xFF, 0, 0, 0, 0];
        let result = ParamValue::deserialize(&data);
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("Unknown ParamValue tag"));
    }
}

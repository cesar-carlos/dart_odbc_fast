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
                ParamValue::Integer(i32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]))
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

pub fn param_values_to_strings(params: &[ParamValue]) -> Result<Vec<String>> {
    let mut out = Vec::with_capacity(params.len());
    for p in params {
        match p {
            ParamValue::Null => {
                return Err(crate::error::OdbcError::ValidationError(
                    "NULL parameters not supported yet".to_string(),
                ));
            }
            ParamValue::String(s) => out.push(s.clone()),
            ParamValue::Integer(n) => out.push(n.to_string()),
            ParamValue::BigInt(n) => out.push(n.to_string()),
            ParamValue::Decimal(s) => out.push(s.clone()),
            ParamValue::Binary(b) => {
                out.push(b.iter().map(|x| format!("{:02x}", x)).collect::<String>());
            }
        }
    }
    Ok(out)
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
}

use crate::error::{OdbcError, Result};
use odbc_api::{
    handles::ParameterDescription,
    parameter::{InputParameter, VarBinaryBox, WithDataType},
    DataType, IntoParameter, Nullability, Nullable,
};

#[cfg(windows)]
type NullTextBox = odbc_api::parameter::VarWCharBox;
#[cfg(not(windows))]
type NullTextBox = odbc_api::parameter::VarCharBox;

const TAG_NULL: u8 = 0;
const TAG_STRING: u8 = 1;
const TAG_INTEGER: u8 = 2;
const TAG_BIGINT: u8 = 3;
const TAG_DECIMAL: u8 = 4;
const TAG_BINARY: u8 = 5;
/// Placeholder for Oracle `SYS_REFCURSOR` / similar `OUT` parameters (wire
/// tag only; engine bind is engine-specific — see `TYPE_MAPPING` §3.1.1).
const TAG_REF_CURSOR_OUT: u8 = 6;
pub const MAX_PARAM_COUNT: usize = 4096;
pub const MAX_PARAM_VALUE_PAYLOAD_LEN: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq)]
pub enum ParamValue {
    String(String),
    Integer(i32),
    BigInt(i64),
    Decimal(String),
    Binary(Vec<u8>),
    Null,
    /// Output-only marker: materialized rows may follow in an `RC1\0` trailer.
    RefCursorOut,
}

impl ParamValue {
    pub fn serialize(&self) -> Vec<u8> {
        self.try_serialize()
            .expect("ParamValue exceeds binary protocol limits")
    }

    pub fn try_serialize(&self) -> Result<Vec<u8>> {
        let mut out = Vec::with_capacity(self.serialized_len()?);
        self.write_to_vec(&mut out)?;
        Ok(out)
    }

    fn serialized_len(&self) -> Result<usize> {
        let payload_len = match self {
            ParamValue::String(s) => checked_payload_len(s.len(), "ParamValue::String")? as usize,
            ParamValue::Decimal(s) => checked_payload_len(s.len(), "ParamValue::Decimal")? as usize,
            ParamValue::Binary(b) => checked_payload_len(b.len(), "ParamValue::Binary")? as usize,
            ParamValue::Integer(_) => 4,
            ParamValue::BigInt(_) => 8,
            ParamValue::Null | ParamValue::RefCursorOut => 0,
        };
        Ok(5 + payload_len)
    }

    fn write_to_vec(&self, out: &mut Vec<u8>) -> Result<()> {
        match self {
            ParamValue::Null => {
                out.push(TAG_NULL);
                out.extend_from_slice(&0u32.to_le_bytes());
            }
            ParamValue::String(s) => {
                out.push(TAG_STRING);
                let b = s.as_bytes();
                let len = checked_payload_len(b.len(), "ParamValue::String")?;
                out.extend_from_slice(&len.to_le_bytes());
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
                let len = checked_payload_len(b.len(), "ParamValue::Decimal")?;
                out.extend_from_slice(&len.to_le_bytes());
                out.extend_from_slice(b);
            }
            ParamValue::Binary(b) => {
                out.push(TAG_BINARY);
                let len = checked_payload_len(b.len(), "ParamValue::Binary")?;
                out.extend_from_slice(&len.to_le_bytes());
                out.extend_from_slice(b);
            }
            ParamValue::RefCursorOut => {
                out.push(TAG_REF_CURSOR_OUT);
                out.extend_from_slice(&0u32.to_le_bytes());
            }
        }
        Ok(())
    }

    pub fn deserialize(data: &[u8]) -> Result<(Self, usize)> {
        if data.len() < 5 {
            return Err(OdbcError::ValidationError(
                "ParamValue buffer too short".to_string(),
            ));
        }
        let tag = data[0];
        let len = u32::from_le_bytes([data[1], data[2], data[3], data[4]]) as usize;
        if len > MAX_PARAM_VALUE_PAYLOAD_LEN {
            return Err(OdbcError::ValidationError(format!(
                "ParamValue payload length {} exceeds limit {}",
                len, MAX_PARAM_VALUE_PAYLOAD_LEN
            )));
        }
        let consumed = 5usize
            .checked_add(len)
            .ok_or_else(|| OdbcError::ValidationError("ParamValue length overflow".to_string()))?;

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
            TAG_REF_CURSOR_OUT => {
                if len != 0 {
                    return Err(OdbcError::ValidationError(
                        "ParamValue::RefCursorOut expected 0-byte payload".to_string(),
                    ));
                }
                ParamValue::RefCursorOut
            }
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
        if out.len() >= MAX_PARAM_COUNT {
            return Err(OdbcError::ValidationError(format!(
                "Parameter count exceeds limit {}",
                MAX_PARAM_COUNT
            )));
        }
        let (p, n) = ParamValue::deserialize(&data[offset..])?;
        out.push(p);
        offset += n;
    }
    Ok(out)
}

pub fn serialize_params(params: &[ParamValue]) -> Vec<u8> {
    try_serialize_params(params).expect("parameter list exceeds binary protocol limits")
}

pub fn try_serialize_params(params: &[ParamValue]) -> Result<Vec<u8>> {
    if params.len() > MAX_PARAM_COUNT {
        return Err(OdbcError::ValidationError(format!(
            "Parameter count {} exceeds limit {}",
            params.len(),
            MAX_PARAM_COUNT
        )));
    }
    let capacity = params.iter().try_fold(0usize, |acc, param| {
        let len = param.serialized_len()?;
        acc.checked_add(len).ok_or_else(|| {
            OdbcError::ResourceLimitReached("parameter buffer size overflow".to_string())
        })
    })?;
    let mut out = Vec::with_capacity(capacity);
    for p in params {
        p.write_to_vec(&mut out)?;
    }
    Ok(out)
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
                out.push(Some(bytes_to_lower_hex(b)));
            }
            ParamValue::RefCursorOut => {
                return Err(OdbcError::ValidationError(
                    "ParamValue::RefCursorOut is not convertible to string parameters".to_string(),
                ));
            }
        }
    }
    Ok(out)
}

fn bytes_to_lower_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &byte in bytes {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

pub fn param_value_to_input_parameter(param: &ParamValue) -> Result<Box<dyn InputParameter>> {
    match param {
        ParamValue::Null => Ok(Box::new(Option::<String>::None.into_parameter())),
        ParamValue::String(s) => Ok(Box::new(s.clone().into_parameter())),
        ParamValue::Integer(n) => Ok(Box::new((*n).into_parameter())),
        ParamValue::BigInt(n) => Ok(Box::new((*n).into_parameter())),
        ParamValue::Decimal(s) => Ok(Box::new(s.clone().into_parameter())),
        ParamValue::Binary(b) => Ok(Box::new(b.clone().into_parameter())),
        ParamValue::RefCursorOut => Err(OdbcError::ValidationError(
            "ParamValue::RefCursorOut is not bindable as an input parameter".to_string(),
        )),
    }
}

pub fn param_values_to_input_params(params: &[ParamValue]) -> Result<Vec<Box<dyn InputParameter>>> {
    params.iter().map(param_value_to_input_parameter).collect()
}

pub fn param_values_to_input_params_with_inference(
    params: &[ParamValue],
) -> Result<Option<Vec<Box<dyn InputParameter>>>> {
    let inferred_kind = match infer_shared_non_null_kind(params) {
        Some(kind) => kind,
        None => return Ok(None),
    };

    params
        .iter()
        .map(|param| input_parameter_for_inferred_kind(param, inferred_kind))
        .collect::<Result<Vec<_>>>()
        .map(Some)
}

pub fn param_values_to_input_params_with_descriptions(
    params: &[ParamValue],
    descriptions: &[ParameterDescription],
) -> Result<Vec<Box<dyn InputParameter>>> {
    if params.len() != descriptions.len() {
        return Err(OdbcError::ValidationError(format!(
            "Parameter description count {} does not match parameter count {}",
            descriptions.len(),
            params.len()
        )));
    }

    let inferred_null_kind = infer_shared_non_null_kind(params);

    params
        .iter()
        .zip(descriptions.iter())
        .map(|(param, description)| {
            input_parameter_for_description(param, *description, inferred_null_kind)
        })
        .collect()
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
            ParamValue::RefCursorOut => 0,
            _ => 0,
        };
        max_len = max_len.max(len);
    }
    max_len
}

pub fn param_count_exceeds_limit(params: &[ParamValue], limit: usize) -> bool {
    params.len() > limit
}

fn checked_payload_len(value: usize, field: &'static str) -> Result<u32> {
    if value > MAX_PARAM_VALUE_PAYLOAD_LEN {
        return Err(OdbcError::ValidationError(format!(
            "{} length {} exceeds limit {}",
            field, value, MAX_PARAM_VALUE_PAYLOAD_LEN
        )));
    }
    value
        .try_into()
        .map_err(|_| OdbcError::ValidationError(format!("{} length {} exceeds u32", field, value)))
}

fn null_input_parameter_for_description(
    description: ParameterDescription,
) -> Result<Box<dyn InputParameter>> {
    if description.nullability == Nullability::NoNulls {
        return Err(OdbcError::ValidationError(
            "Parameter does not accept NULL according to driver metadata".to_string(),
        ));
    }

    Ok(match description.data_type {
        DataType::Integer => Box::new(WithDataType::new(
            Nullable::<i32>::null(),
            DataType::Integer,
        )),
        DataType::SmallInt => Box::new(WithDataType::new(
            Nullable::<i16>::null(),
            DataType::SmallInt,
        )),
        DataType::BigInt => Box::new(WithDataType::new(Nullable::<i64>::null(), DataType::BigInt)),
        DataType::TinyInt | DataType::Bit => Box::new(WithDataType::new(
            Nullable::<u8>::null(),
            description.data_type,
        )),
        DataType::Real => Box::new(WithDataType::new(Nullable::<f32>::null(), DataType::Real)),
        DataType::Float { .. } | DataType::Double => Box::new(WithDataType::new(
            Nullable::<f64>::null(),
            description.data_type,
        )),
        DataType::Binary { .. } | DataType::Varbinary { .. } | DataType::LongVarbinary { .. } => {
            Box::new(WithDataType::new(
                VarBinaryBox::null(),
                description.data_type,
            ))
        }
        _ => Box::new(WithDataType::new(
            NullTextBox::null(),
            description.data_type,
        )),
    })
}

fn input_parameter_for_description(
    param: &ParamValue,
    description: ParameterDescription,
    inferred_null_kind: Option<InferredNullKind>,
) -> Result<Box<dyn InputParameter>> {
    match param {
        ParamValue::Null => {
            if has_usable_description_type(description.data_type) {
                null_input_parameter_for_description(description)
            } else if let Some(kind) = inferred_null_kind {
                null_input_parameter_for_inferred_kind(kind)
            } else {
                param_value_to_input_parameter(param)
            }
        }
        ParamValue::String(_) => param_value_to_input_parameter(param),
        ParamValue::Integer(n) => {
            if has_usable_description_type(description.data_type) {
                Ok(Box::new(WithDataType::new(*n, description.data_type)))
            } else {
                param_value_to_input_parameter(param)
            }
        }
        ParamValue::BigInt(n) => {
            if has_usable_description_type(description.data_type) {
                Ok(Box::new(WithDataType::new(*n, description.data_type)))
            } else {
                param_value_to_input_parameter(param)
            }
        }
        ParamValue::Decimal(_) => param_value_to_input_parameter(param),
        ParamValue::Binary(_) => param_value_to_input_parameter(param),
        ParamValue::RefCursorOut => Err(OdbcError::ValidationError(
            "ParamValue::RefCursorOut is not bindable as an input parameter".to_string(),
        )),
    }
}

fn input_parameter_for_inferred_kind(
    param: &ParamValue,
    inferred_kind: InferredNullKind,
) -> Result<Box<dyn InputParameter>> {
    match (param, inferred_kind) {
        (ParamValue::Null, kind) => null_input_parameter_for_inferred_kind(kind),
        (ParamValue::Integer(n), InferredNullKind::BigInt) => {
            Ok(Box::new(WithDataType::new(i64::from(*n), DataType::BigInt)))
        }
        _ => param_value_to_input_parameter(param),
    }
}

#[derive(Clone, Copy)]
enum InferredNullKind {
    Integer,
    BigInt,
    Decimal,
    Binary,
    String,
}

fn infer_shared_non_null_kind(params: &[ParamValue]) -> Option<InferredNullKind> {
    let mut inferred: Option<InferredNullKind> = None;

    for param in params {
        let current = match param {
            ParamValue::Null => continue,
            ParamValue::Integer(_) => InferredNullKind::Integer,
            ParamValue::BigInt(_) => InferredNullKind::BigInt,
            ParamValue::Decimal(_) => InferredNullKind::Decimal,
            ParamValue::Binary(_) => InferredNullKind::Binary,
            ParamValue::String(_) => InferredNullKind::String,
            ParamValue::RefCursorOut => return None,
        };

        match inferred {
            None => inferred = Some(current),
            Some(existing)
                if std::mem::discriminant(&existing) == std::mem::discriminant(&current) => {}
            Some(InferredNullKind::Integer) if matches!(current, InferredNullKind::BigInt) => {
                inferred = Some(InferredNullKind::BigInt);
            }
            Some(InferredNullKind::BigInt) if matches!(current, InferredNullKind::Integer) => {}
            Some(_) => return None,
        }
    }

    inferred
}

fn null_input_parameter_for_inferred_kind(
    kind: InferredNullKind,
) -> Result<Box<dyn InputParameter>> {
    Ok(match kind {
        InferredNullKind::Integer => Box::new(WithDataType::new(
            Nullable::<i32>::null(),
            DataType::Integer,
        )),
        InferredNullKind::BigInt => {
            Box::new(WithDataType::new(Nullable::<i64>::null(), DataType::BigInt))
        }
        InferredNullKind::Decimal => Box::new(WithDataType::new(
            NullTextBox::null(),
            DataType::Varchar { length: None },
        )),
        InferredNullKind::Binary => Box::new(WithDataType::new(
            VarBinaryBox::null(),
            DataType::Varbinary { length: None },
        )),
        InferredNullKind::String => Box::new(WithDataType::new(
            NullTextBox::null(),
            DataType::Varchar { length: None },
        )),
    })
}

fn has_usable_description_type(data_type: DataType) -> bool {
    !matches!(data_type, DataType::Unknown | DataType::Other { .. })
}

#[cfg(test)]
mod tests {
    use super::*;
    use odbc_api::{
        handles::{HasDataType, ParameterDescription},
        DataType, Nullability,
    };
    use std::num::NonZeroUsize;

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
    fn test_param_value_ref_cursor_out_roundtrip() {
        let p = ParamValue::RefCursorOut;
        let enc = p.serialize();
        assert_eq!(enc, vec![6, 0, 0, 0, 0]);
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

    #[test]
    fn test_deserialize_rejects_huge_payload_length_before_slice() {
        let data = vec![TAG_STRING, 0xff, 0xff, 0xff, 0xff];

        let result = ParamValue::deserialize(&data);

        assert!(result.unwrap_err().to_string().contains("payload length"));
    }

    #[test]
    fn test_serialize_params_rejects_too_many_params() {
        let params = vec![ParamValue::Null; MAX_PARAM_COUNT + 1];

        let result = try_serialize_params(&params);

        assert!(result.unwrap_err().to_string().contains("Parameter count"));
    }

    #[test]
    fn test_deserialize_params_rejects_too_many_params() {
        let enc_one = ParamValue::Null.try_serialize().expect("ok");
        let mut buf = Vec::new();
        for _ in 0..(MAX_PARAM_COUNT + 1) {
            buf.extend_from_slice(&enc_one);
        }
        let err = deserialize_params(&buf).expect_err("decode must fail");
        assert!(err.to_string().contains("Parameter count exceeds limit"));
    }

    #[test]
    fn test_param_values_to_strings_rejects_ref_cursor() {
        let r = param_values_to_strings(&[ParamValue::RefCursorOut]);
        let msg = r.expect_err("RefCursor out").to_string();
        assert!(msg.contains("not convertible to string"));
    }

    #[test]
    fn test_param_value_to_input_parameter_accepts_integer_and_binary() {
        let int_param =
            param_value_to_input_parameter(&ParamValue::Integer(7)).expect("int param should bind");
        let binary_param = param_value_to_input_parameter(&ParamValue::Binary(vec![1, 2, 3]))
            .expect("binary param should bind");

        assert_eq!(int_param.data_type(), 4_i32.data_type());
        assert_eq!(
            binary_param.data_type(),
            vec![1_u8, 2, 3].into_parameter().data_type()
        );
    }

    #[test]
    fn test_param_value_to_input_parameter_rejects_ref_cursor() {
        let err = match param_value_to_input_parameter(&ParamValue::RefCursorOut) {
            Ok(_) => panic!("RefCursorOut must not bind as input"),
            Err(err) => err,
        };
        assert!(err.to_string().contains("not bindable as an input"));
    }

    #[test]
    fn test_param_values_to_input_params_with_descriptions_uses_integer_null_type() {
        let params = [ParamValue::Null];
        let descriptions = [ParameterDescription {
            nullability: Nullability::Nullable,
            data_type: DataType::Integer,
        }];

        let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
            .expect("described NULL should bind");

        assert_eq!(bound.len(), 1);
        assert_eq!(bound[0].data_type(), 4_i32.data_type());
    }

    #[test]
    fn test_param_values_to_input_params_with_descriptions_uses_binary_null_type() {
        let params = [ParamValue::Null];
        let descriptions = [ParameterDescription {
            nullability: Nullability::Nullable,
            data_type: DataType::Varbinary {
                length: Some(NonZeroUsize::new(32).expect("non-zero")),
            },
        }];

        let bound = param_values_to_input_params_with_descriptions(&params, &descriptions)
            .expect("binary NULL should bind");

        assert_eq!(bound.len(), 1);
        assert_eq!(
            bound[0].data_type(),
            DataType::Varbinary {
                length: Some(NonZeroUsize::new(32).expect("non-zero")),
            },
        );
    }

    #[test]
    fn test_param_values_to_input_params_with_descriptions_rejects_non_nullable_null() {
        let params = [ParamValue::Null];
        let descriptions = [ParameterDescription {
            nullability: Nullability::NoNulls,
            data_type: DataType::Integer,
        }];

        let err = match param_values_to_input_params_with_descriptions(&params, &descriptions) {
            Ok(_) => panic!("non-nullable metadata must reject NULL"),
            Err(err) => err,
        };

        assert!(err.to_string().contains("does not accept NULL"));
    }

    #[test]
    fn test_param_values_to_input_params_with_inference_promotes_integer_family_to_bigint() {
        let params = [
            ParamValue::Integer(7),
            ParamValue::Null,
            ParamValue::BigInt(9),
        ];

        let bound = param_values_to_input_params_with_inference(&params)
            .expect("inference should succeed")
            .expect("mixed integer family should infer");

        assert_eq!(bound.len(), 3);
        assert_eq!(bound[0].data_type(), DataType::BigInt);
        assert_eq!(bound[1].data_type(), DataType::BigInt);
        assert_eq!(bound[2].data_type(), DataType::BigInt);
    }

    #[test]
    fn test_param_values_to_input_params_with_inference_returns_none_for_mixed_families() {
        let params = [
            ParamValue::Integer(7),
            ParamValue::Null,
            ParamValue::String("x".into()),
        ];

        let bound = param_values_to_input_params_with_inference(&params)
            .expect("inference should not error");

        assert!(bound.is_none());
    }

    #[test]
    fn test_try_serialize_string_rejects_huge_payload() {
        let s = "x".repeat(MAX_PARAM_VALUE_PAYLOAD_LEN + 1);
        let r = ParamValue::String(s).try_serialize();
        let msg = r.expect_err("oversize").to_string();
        assert!(msg.contains("ParamValue::String"));
        assert!(msg.contains("exceeds limit"));
    }

    #[test]
    fn test_deserialize_ref_cursor_rejects_non_empty_payload() {
        let mut data = vec![TAG_REF_CURSOR_OUT];
        data.extend_from_slice(&1u32.to_le_bytes());
        data.push(0);
        let err = ParamValue::deserialize(&data).expect_err("non-empty ref cursor");
        assert!(
            err.to_string().contains("0-byte payload"),
            "unexpected: {err:?}"
        );
    }

    #[test]
    fn test_deserialize_params_rejects_incomplete_second_param() {
        let mut buf = ParamValue::Null.serialize();
        buf.push(0xff);
        let err = deserialize_params(&buf).expect_err("trailing/incomplete");
        assert!(err.to_string().contains("too short"), "unexpected: {err:?}");
    }

    #[test]
    fn test_param_values_to_strings_empty_binary_hex() {
        let params = [ParamValue::Binary(vec![])];
        let out = param_values_to_strings(&params).expect("strings");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0], Some(String::new()));
    }
}

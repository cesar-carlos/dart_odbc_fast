//! Directed parameter list (DRT1 wire) — [magic][count][(direction)(ParamValue)]*. Legacy buffers
//! without the magic are plain concatenated [ParamValue] values (all input).

use crate::error::{OdbcError, Result};
use crate::protocol::param_value::{ParamValue, MAX_PARAM_COUNT};

const DRT1: [u8; 4] = *b"DRT1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ParamDirection {
    Input = 0,
    Output = 1,
    InOut = 2,
}

impl ParamDirection {
    fn from_u8(b: u8) -> Option<Self> {
        match b {
            0 => Some(Self::Input),
            1 => Some(Self::Output),
            2 => Some(Self::InOut),
            _ => None,
        }
    }
}

/// One logical ODBC parameter: direction and payload (nullability lives in [ParamValue]).
#[derive(Debug, Clone, PartialEq)]
pub struct BoundParam {
    pub direction: ParamDirection,
    pub value: ParamValue,
}

/// Parsed request buffer: legacy (all `Input`) or directed list.
#[derive(Debug, Clone, PartialEq)]
pub enum ParamList {
    Legacy(Vec<ParamValue>),
    Directed(Vec<BoundParam>),
}

/// True when the buffer is a DRT1 directed list (not legacy concatenation).
pub fn is_directed_param_buffer(data: &[u8]) -> bool {
    data.len() >= 8 && data[..4] == DRT1
}

/// Deserialize a parameter request buffer from the Dart/FFI layer.
/// Legacy: contatenated [ParamValue] (same as [crate::protocol::deserialize_params]).
/// DRT1: `DRT1` + u32 le count + repeated (u8 direction + ParamValue).
pub fn deserialize_param_buffer(data: &[u8]) -> Result<ParamList> {
    if data.is_empty() {
        return Ok(ParamList::Legacy(Vec::new()));
    }
    if is_directed_param_buffer(data) {
        let count = u32::from_le_bytes([data[4], data[5], data[6], data[7]]) as usize;
        if count > MAX_PARAM_COUNT {
            return Err(OdbcError::ValidationError(format!(
                "DRT1 parameter count {} exceeds limit {}",
                count, MAX_PARAM_COUNT
            )));
        }
        let remaining = data.len().saturating_sub(8);
        if count > remaining {
            return Err(OdbcError::ValidationError(
                "DRT1 parameter count exceeds available payload".to_string(),
            ));
        }
        let mut out = Vec::with_capacity(count);
        let mut offset = 8usize;
        for _ in 0..count {
            if offset >= data.len() {
                return Err(OdbcError::ValidationError(
                    "DRT1 buffer truncated (direction)".to_string(),
                ));
            }
            let dir = ParamDirection::from_u8(data[offset]).ok_or_else(|| {
                OdbcError::ValidationError(format!("DRT1 invalid direction {}", data[offset]))
            })?;
            offset += 1;
            if offset >= data.len() {
                return Err(OdbcError::ValidationError(
                    "DRT1 buffer truncated (value)".to_string(),
                ));
            }
            let (value, n) = ParamValue::deserialize(&data[offset..])?;
            offset += n;
            out.push(BoundParam {
                direction: dir,
                value,
            });
        }
        if offset != data.len() {
            return Err(OdbcError::ValidationError(
                "DRT1 buffer has trailing bytes".to_string(),
            ));
        }
        return Ok(ParamList::Directed(out));
    }
    // Legacy: reuse existing
    use crate::protocol::deserialize_params;
    Ok(ParamList::Legacy(deserialize_params(data)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drt1_round_trip_count() {
        let one = ParamValue::Integer(3);
        let one_bytes = one.serialize();
        // Build DRT1 buffer manually: DRT1 + u32(1) + 0u8 + bytes
        let mut buf: Vec<u8> = DRT1.to_vec();
        buf.extend_from_slice(&1u32.to_le_bytes());
        buf.push(0u8);
        buf.extend_from_slice(&one_bytes);
        let p = deserialize_param_buffer(&buf).expect("drt1");
        match p {
            ParamList::Directed(v) => {
                assert_eq!(v.len(), 1);
                assert_eq!(v[0].direction, ParamDirection::Input);
                assert_eq!(v[0].value, ParamValue::Integer(3));
            }
            _ => panic!("expected directed"),
        }
    }

    #[test]
    fn legacy_still_parses() {
        let p = ParamValue::String("x".to_string());
        let mut v = p.serialize();
        v.extend(p.serialize());
        let list = deserialize_param_buffer(&v).expect("ok");
        match list {
            ParamList::Legacy(x) => assert_eq!(x.len(), 2),
            _ => panic!("expected legacy"),
        }
    }

    #[test]
    fn drt1_out_integer() {
        let v = ParamValue::Null;
        let vb = v.serialize();
        let mut buf: Vec<u8> = DRT1.to_vec();
        buf.extend_from_slice(&1u32.to_le_bytes());
        buf.push(1u8); // Output
        buf.extend_from_slice(&vb);
        let list = deserialize_param_buffer(&buf).expect("drt1 out");
        match list {
            ParamList::Directed(b) => {
                assert_eq!(b[0].direction, ParamDirection::Output);
                assert_eq!(b[0].value, ParamValue::Null);
            }
            _ => panic!(""),
        }
    }

    #[test]
    fn drt1_rejects_huge_count_before_allocation() {
        let mut buf: Vec<u8> = DRT1.to_vec();
        buf.extend_from_slice(&u32::MAX.to_le_bytes());

        let result = deserialize_param_buffer(&buf);

        assert!(result.unwrap_err().to_string().contains("parameter count"));
    }

    #[test]
    fn drt1_rejects_trailing_bytes() {
        let one = ParamValue::Null;
        let b = one.serialize();
        let mut buf: Vec<u8> = DRT1.to_vec();
        buf.extend_from_slice(&1u32.to_le_bytes());
        buf.push(0u8);
        buf.extend_from_slice(&b);
        buf.push(0xff);
        let e = deserialize_param_buffer(&buf).expect_err("trailing");
        assert!(e.to_string().contains("trailing bytes"));
    }

    #[test]
    fn drt1_rejects_invalid_direction() {
        let b = ParamValue::Null.serialize();
        let mut buf: Vec<u8> = DRT1.to_vec();
        buf.extend_from_slice(&1u32.to_le_bytes());
        buf.push(3u8);
        buf.extend_from_slice(&b);
        let e = deserialize_param_buffer(&buf).expect_err("dir");
        assert!(e.to_string().contains("invalid direction"));
    }

    #[test]
    fn drt1_rejects_count_exceeds_payload() {
        let mut buf: Vec<u8> = DRT1.to_vec();
        buf.extend_from_slice(&10u32.to_le_bytes());
        let e = deserialize_param_buffer(&buf).expect_err("count");
        assert!(e.to_string().contains("exceeds available"));
    }
}

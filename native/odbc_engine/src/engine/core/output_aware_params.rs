//! Dynamic ODBC parameter binding (Input, Output, InOut) for mixed `?` lists.

use crate::error::{OdbcError, Result};
use crate::protocol::bound_param::{BoundParam, ParamDirection};
use crate::protocol::param_value::{param_value_to_input_parameter, ParamValue};

use odbc_api::buffers::Indicator;
use odbc_api::handles::Statement;
use odbc_api::parameter::InputParameter;
use odbc_api::ParameterCollection;
use odbc_api::{sys::ParamType, Nullable};
#[cfg(windows)]
use std::mem::size_of;

#[cfg(windows)]
type TextBox = odbc_api::parameter::VarWCharBox;
#[cfg(not(windows))]
type TextBox = odbc_api::parameter::VarCharBox;

/// Max string payload for wide `OUT` / `INOUT` (SQL Server `nvarchar` scale).
#[cfg(windows)]
const OUT_TEXT_MAX_CODE_UNITS: usize = 4000;
/// Max bytes for narrow `OUT` / `INOUT` (typical `varchar(8000)` / UTF-8 upper bound for ASCII).
#[cfg(not(windows))]
const OUT_TEXT_MAX_CODE_UNITS: usize = 8000;

/// Owned parameter slots (one per `?` placeholder).
pub(crate) struct OutputAwareParams {
    pub slots: Vec<ParamSlot>,
}

/// Discriminated bind storage.
pub(crate) enum ParamSlot {
    InAny(Box<dyn InputParameter>),
    OutI32(Nullable<i32>),
    OutI64(Nullable<i64>),
    InOutI32(Nullable<i32>),
    InOutI64(Nullable<i64>),
    OutText(TextBox),
    InOutText(TextBox),
}

/// Empty receive buffer for textual `OUT` (wide or narrow) with a terminating nul.
fn out_text_shell() -> TextBox {
    let cap_elems = OUT_TEXT_MAX_CODE_UNITS + 1;
    #[cfg(windows)]
    {
        let buf: Vec<u16> = vec![0u16; cap_elems];
        let byte_len = buf.len() * size_of::<u16>();
        TextBox::from_buffer(buf.into_boxed_slice(), Indicator::Length(byte_len))
    }
    #[cfg(not(windows))]
    {
        let buf: Vec<u8> = vec![0u8; cap_elems];
        let bytes = buf.len();
        TextBox::from_buffer(buf.into_boxed_slice(), Indicator::Length(bytes))
    }
}

fn inout_text_from_str(s: &str) -> Result<TextBox> {
    #[cfg(windows)]
    {
        let u: Vec<u16> = s.encode_utf16().collect();
        if u.len() > OUT_TEXT_MAX_CODE_UNITS {
            return Err(validation_directed(format!(
                "inout_string_too_long: INOUT exceeds {OUT_TEXT_MAX_CODE_UNITS} UTF-16 code units"
            )));
        }
        let cap_elems = OUT_TEXT_MAX_CODE_UNITS + 1;
        let mut buf = vec![0u16; cap_elems];
        buf[..u.len()].copy_from_slice(&u);
        let in_bytes = u.len() * size_of::<u16>();
        Ok(TextBox::from_buffer(
            buf.into_boxed_slice(),
            Indicator::Length(in_bytes),
        ))
    }
    #[cfg(not(windows))]
    {
        let b = s.as_bytes();
        if b.len() > OUT_TEXT_MAX_CODE_UNITS {
            return Err(validation_directed(format!(
                "inout_string_too_long: INOUT exceeds {OUT_TEXT_MAX_CODE_UNITS} bytes"
            )));
        }
        let cap_elems = OUT_TEXT_MAX_CODE_UNITS + 1;
        let mut buf = vec![0u8; cap_elems];
        let blen = b.len();
        buf[..blen].copy_from_slice(b);
        Ok(TextBox::from_buffer(
            buf.into_boxed_slice(),
            Indicator::Length(blen),
        ))
    }
}

/// Stable `ValidationError` prefix so Dart hosts can branch or log; keep text after `|`
/// as the human message (do not break by trimming before `|`).
const ERR_PREFIX: &str = "DIRECTED_PARAM|";

fn validation_directed(msg: impl Into<String>) -> OdbcError {
    OdbcError::ValidationError(format!("{ERR_PREFIX}{}", msg.into()))
}

fn decimal_payload(d: &str) -> Result<&str> {
    if d.is_empty() {
        return Err(validation_directed(
            "decimal_inout_out_requires_non_empty: use a non-empty \
             ParamValue::Decimal for OUT/INOUT or use String",
        ));
    }
    Ok(d)
}

/// Maps [BoundParam] to ODBC bind slots.
pub(crate) fn bound_to_slots(bound: &[BoundParam]) -> Result<OutputAwareParams> {
    let mut slots = Vec::with_capacity(bound.len());
    for bp in bound {
        let slot = match (bp.direction, &bp.value) {
            (ParamDirection::Input, ParamValue::RefCursorOut) => {
                return Err(validation_directed(
                    "ref_cursor_out_invalid_direction: ParamValue::RefCursorOut is only \
                     valid for ParamDirection::output",
                ));
            }
            (ParamDirection::Input, v) => ParamSlot::InAny(param_value_to_input_parameter(v)?),
            (ParamDirection::Output, ParamValue::RefCursorOut)
            | (ParamDirection::InOut, ParamValue::RefCursorOut) => {
                // The Oracle *directed* path uses `ref_cursor_oracle::filter_…` and never calls
                // `bound_to_slots` with `RefCursorOut`. If you see this, it is a bug or a caller
                // bypassing `execute_oracle_ref_cursor_path`.
                // See `doc/notes/REF_CURSOR_ORACLE_ROADMAP.md` (defensive; not the happy path).
                return Err(validation_directed(
                    "ref_cursor_out_bind_not_enabled: ParamValue::RefCursorOut in bound_to_slots; \
                     use the Oracle ref-cursor path (strip + more_results) or filter markers first \
                     (TYPE_MAPPING §3.1.1).",
                ));
            }
            (ParamDirection::Output, ParamValue::Null) => ParamSlot::OutI32(Nullable::null()),
            (ParamDirection::Output, ParamValue::Integer(_)) => ParamSlot::OutI32(Nullable::null()),
            (ParamDirection::Output, ParamValue::BigInt(_)) => ParamSlot::OutI64(Nullable::null()),
            (ParamDirection::Output, ParamValue::String(_)) => ParamSlot::OutText(out_text_shell()),
            (ParamDirection::Output, ParamValue::Decimal(d)) => {
                let _ = decimal_payload(d)?;
                ParamSlot::OutText(out_text_shell())
            }
            (ParamDirection::InOut, ParamValue::Integer(n)) => {
                ParamSlot::InOutI32(Nullable::new(*n))
            }
            (ParamDirection::InOut, ParamValue::BigInt(n)) => {
                ParamSlot::InOutI64(Nullable::new(*n))
            }
            (ParamDirection::InOut, ParamValue::String(s)) => {
                ParamSlot::InOutText(inout_text_from_str(s)?)
            }
            (ParamDirection::InOut, ParamValue::Decimal(d)) => {
                ParamSlot::InOutText(inout_text_from_str(decimal_payload(d)?)?)
            }
            (ParamDirection::InOut, ParamValue::Null) => {
                return Err(validation_directed(
                    "inout_null: INOUT with ParamValue::Null is not supported; pass Integer, \
                     BigInt, String, or non-empty Decimal",
                ));
            }
            (ParamDirection::Output, ParamValue::Binary(_))
            | (ParamDirection::InOut, ParamValue::Binary(_)) => {
                return Err(validation_directed(
                    "binary_out_inout_not_implemented: OUT/INOUT for binary columns is not \
                     implemented; use Integer, BigInt, String, or Decimal (see TYPE_MAPPING §3.1)",
                ));
            }
        };
        slots.push(slot);
    }
    Ok(OutputAwareParams { slots })
}

fn textbox_to_output_param(t: &TextBox) -> ParamValue {
    #[cfg(windows)]
    {
        match t.as_utf16() {
            None => ParamValue::Null,
            Some(w) => {
                let s = String::from_utf16_lossy(w.as_slice());
                ParamValue::String(s)
            }
        }
    }
    #[cfg(not(windows))]
    {
        match t.as_bytes() {
            None => ParamValue::Null,
            Some(bytes) => ParamValue::String(String::from_utf8_lossy(bytes).into_owned()),
        }
    }
}

impl OutputAwareParams {
    /// One [ParamValue] per `OUT` / `INOUT` slot, in `?` order (input slots not listed).
    pub fn output_footer_values(&self) -> Vec<ParamValue> {
        let mut v = Vec::new();
        for s in &self.slots {
            match s {
                ParamSlot::InAny(_) => {}
                ParamSlot::OutI32(n) | ParamSlot::InOutI32(n) => {
                    let t = *n;
                    v.push(
                        t.into_opt()
                            .map(ParamValue::Integer)
                            .unwrap_or(ParamValue::Null),
                    );
                }
                ParamSlot::OutI64(n) | ParamSlot::InOutI64(n) => {
                    let t = *n;
                    v.push(
                        t.into_opt()
                            .map(ParamValue::BigInt)
                            .unwrap_or(ParamValue::Null),
                    );
                }
                ParamSlot::OutText(t) | ParamSlot::InOutText(t) => {
                    v.push(textbox_to_output_param(t));
                }
            }
        }
        v
    }
}

// SAFETY: slots are built from validated `ParamValue`s; each bind uses owned buffers
// and 1-based ODBC indices within `slots.len()`.
unsafe impl ParameterCollection for OutputAwareParams {
    fn parameter_set_size(&self) -> usize {
        1
    }

    // SAFETY: `stmt` is the active ODBC statement; each slot bind uses buffers owned
    // by `self` and documents per-arm invariants below.
    unsafe fn bind_parameters_to(
        &mut self,
        stmt: &mut impl Statement,
    ) -> std::result::Result<(), odbc_api::Error> {
        for (i, slot) in self.slots.iter_mut().enumerate() {
            let num = (i + 1) as u16;
            match slot {
                ParamSlot::InAny(t) => {
                    // SAFETY: `t` is a boxed `InputParameter` built from validated
                    // `ParamValue` in `bound_to_slots`; `num` is a 1-based ODBC index.
                    unsafe { stmt.bind_input_parameter(num, t) }.into_result(stmt)?;
                }
                ParamSlot::OutI32(n) => {
                    // SAFETY: `n` is an owned `Nullable<i32>` output buffer for this slot.
                    unsafe { stmt.bind_parameter(num, ParamType::Output, n) }.into_result(stmt)?;
                }
                ParamSlot::OutI64(n) => {
                    // SAFETY: `n` is an owned `Nullable<i64>` output buffer for this slot.
                    unsafe { stmt.bind_parameter(num, ParamType::Output, n) }.into_result(stmt)?;
                }
                ParamSlot::InOutI32(n) => {
                    // SAFETY: `n` is an owned `Nullable<i32>` in/out buffer for this slot.
                    unsafe { stmt.bind_parameter(num, ParamType::InputOutput, n) }
                        .into_result(stmt)?;
                }
                ParamSlot::InOutI64(n) => {
                    // SAFETY: `n` is an owned `Nullable<i64>` in/out buffer for this slot.
                    unsafe { stmt.bind_parameter(num, ParamType::InputOutput, n) }
                        .into_result(stmt)?;
                }
                ParamSlot::OutText(t) => {
                    // SAFETY: `t` is a `VarCharBox`/`VarWCharBox` sized for ODBC OUT text.
                    unsafe { stmt.bind_parameter(num, ParamType::Output, t) }.into_result(stmt)?;
                }
                ParamSlot::InOutText(t) => {
                    // SAFETY: `t` is a `VarCharBox`/`VarWCharBox` sized for ODBC INOUT text.
                    unsafe { stmt.bind_parameter(num, ParamType::InputOutput, t) }
                        .into_result(stmt)?;
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::bound_param::ParamDirection;
    use crate::protocol::param_value::ParamValue;

    fn bp(dir: ParamDirection, v: ParamValue) -> BoundParam {
        BoundParam {
            direction: dir,
            value: v,
        }
    }

    #[test]
    fn bound_to_slots_accepts_string_out() {
        let p = [bp(
            ParamDirection::Output,
            ParamValue::String(String::new()),
        )];
        let o = bound_to_slots(&p).expect("out string");
        assert_eq!(o.slots.len(), 1);
        match &o.slots[0] {
            ParamSlot::OutText(_) => {}
            _ => panic!("expected OutText"),
        }
    }

    #[test]
    fn bound_to_slots_accepts_inout_string() {
        let p = [bp(
            ParamDirection::InOut,
            ParamValue::String("a".to_string()),
        )];
        let o = bound_to_slots(&p).expect("inout string");
        assert_eq!(o.slots.len(), 1);
        match &o.slots[0] {
            ParamSlot::InOutText(_) => {}
            _ => panic!("expected InOutText"),
        }
    }

    #[test]
    fn bound_to_slots_rejects_binary_out_with_stable_prefix() {
        let p = [bp(ParamDirection::Output, ParamValue::Binary(vec![0u8]))];
        let e = match bound_to_slots(&p) {
            Ok(_) => panic!("expected error"),
            Err(e) => e,
        };
        let OdbcError::ValidationError(m) = e else {
            panic!("expected ValidationError, got {e:?}");
        };
        assert!(
            m.starts_with(super::ERR_PREFIX) && m.contains("binary_out_inout_not_implemented"),
            "{m}"
        );
    }

    #[test]
    fn bound_to_slots_rejects_ref_cursor_out_until_bind() {
        let p = [bp(ParamDirection::Output, ParamValue::RefCursorOut)];
        let e = match bound_to_slots(&p) {
            Ok(_) => panic!("expected error"),
            Err(e) => e,
        };
        let OdbcError::ValidationError(m) = e else {
            panic!("expected ValidationError, got {e:?}");
        };
        assert!(m.contains("ref_cursor_out_bind_not_enabled"), "{m}");
    }

    #[test]
    fn should_map_output_integer_slots_when_bound_to_slots() {
        let o = bound_to_slots(&[bp(ParamDirection::Output, ParamValue::Integer(0))]).unwrap();
        assert!(matches!(o.slots[0], ParamSlot::OutI32(_)));
    }

    #[test]
    fn should_map_output_bigint_and_null_slots_when_bound_to_slots() {
        let o = bound_to_slots(&[
            bp(ParamDirection::Output, ParamValue::BigInt(0)),
            bp(ParamDirection::Output, ParamValue::Null),
        ])
        .unwrap();
        assert!(matches!(o.slots[0], ParamSlot::OutI64(_)));
        assert!(matches!(o.slots[1], ParamSlot::OutI32(_)));
    }

    #[test]
    fn should_map_inout_numeric_slots_when_bound_to_slots() {
        let o = bound_to_slots(&[
            bp(ParamDirection::InOut, ParamValue::Integer(7)),
            bp(ParamDirection::InOut, ParamValue::BigInt(9)),
        ])
        .unwrap();
        match &o.slots[0] {
            ParamSlot::InOutI32(n) => assert_eq!(n.into_opt(), Some(7)),
            _ => panic!("expected InOutI32"),
        }
        match &o.slots[1] {
            ParamSlot::InOutI64(n) => assert_eq!(n.into_opt(), Some(9)),
            _ => panic!("expected InOutI64"),
        }
    }

    #[test]
    fn should_map_output_decimal_to_text_shell_when_bound_to_slots() {
        let o = bound_to_slots(&[bp(
            ParamDirection::Output,
            ParamValue::Decimal("12.34".to_string()),
        )])
        .unwrap();
        assert!(matches!(o.slots[0], ParamSlot::OutText(_)));
    }

    #[test]
    fn should_reject_empty_decimal_out_when_bound_to_slots() {
        let err = bound_to_slots(&[bp(
            ParamDirection::Output,
            ParamValue::Decimal(String::new()),
        )])
        .err()
        .expect("empty decimal output should fail");
        let OdbcError::ValidationError(m) = err else {
            panic!("expected ValidationError");
        };
        assert!(m.contains("decimal_inout_out_requires_non_empty"), "{m}");
    }

    #[test]
    fn should_reject_inout_null_when_bound_to_slots() {
        let err = bound_to_slots(&[bp(ParamDirection::InOut, ParamValue::Null)])
            .err()
            .expect("inout null should fail");
        let OdbcError::ValidationError(m) = err else {
            panic!("expected ValidationError");
        };
        assert!(m.contains("inout_null"), "{m}");
    }

    #[test]
    fn should_reject_ref_cursor_as_input_when_bound_to_slots() {
        let err = bound_to_slots(&[bp(ParamDirection::Input, ParamValue::RefCursorOut)])
            .err()
            .expect("ref cursor as input should fail");
        let OdbcError::ValidationError(m) = err else {
            panic!("expected ValidationError");
        };
        assert!(m.contains("ref_cursor_out_invalid_direction"), "{m}");
    }

    #[test]
    fn should_reject_inout_binary_when_bound_to_slots() {
        let err = bound_to_slots(&[bp(ParamDirection::InOut, ParamValue::Binary(vec![1]))])
            .err()
            .expect("inout binary should fail");
        let OdbcError::ValidationError(m) = err else {
            panic!("expected ValidationError");
        };
        assert!(m.contains("binary_out_inout_not_implemented"), "{m}");
    }

    #[test]
    fn should_reject_inout_string_over_max_code_units_when_bound_to_slots() {
        let too_long = "x".repeat(super::OUT_TEXT_MAX_CODE_UNITS + 1);
        let err = bound_to_slots(&[bp(ParamDirection::InOut, ParamValue::String(too_long))])
            .err()
            .expect("inout string too long should fail");
        let OdbcError::ValidationError(m) = err else {
            panic!("expected ValidationError");
        };
        assert!(m.contains("inout_string_too_long"), "{m}");
    }

    #[test]
    fn should_collect_output_footer_for_mixed_out_slots() {
        let params = bound_to_slots(&[
            bp(ParamDirection::Input, ParamValue::Integer(1)),
            bp(ParamDirection::Output, ParamValue::Integer(0)),
            bp(ParamDirection::InOut, ParamValue::String("hi".to_string())),
        ])
        .unwrap();
        let footer = params.output_footer_values();
        assert_eq!(footer.len(), 2);
        assert_eq!(footer[0], ParamValue::Null);
        assert_eq!(footer[1], ParamValue::String("hi".to_string()));
    }

    #[test]
    fn should_emit_integer_footer_when_inout_i32_has_value() {
        let params = bound_to_slots(&[bp(ParamDirection::InOut, ParamValue::Integer(42))]).unwrap();
        assert_eq!(params.output_footer_values(), vec![ParamValue::Integer(42)]);
    }

    #[test]
    fn should_map_input_params_to_in_any_slots() {
        let params = bound_to_slots(&[bp(ParamDirection::Input, ParamValue::Integer(3))]).unwrap();
        assert!(matches!(params.slots[0], ParamSlot::InAny(_)));
        assert!(params.output_footer_values().is_empty());
    }

    #[test]
    fn should_accept_inout_decimal_when_non_empty() {
        let params = bound_to_slots(&[bp(
            ParamDirection::InOut,
            ParamValue::Decimal("9.99".to_string()),
        )])
        .unwrap();
        assert!(matches!(params.slots[0], ParamSlot::InOutText(_)));
    }

    #[test]
    fn should_reject_empty_decimal_inout_when_bound_to_slots() {
        let err = bound_to_slots(&[bp(
            ParamDirection::InOut,
            ParamValue::Decimal(String::new()),
        )])
        .err()
        .expect("empty decimal inout should fail");
        let OdbcError::ValidationError(m) = err else {
            panic!("expected ValidationError");
        };
        assert!(m.contains("decimal_inout_out_requires_non_empty"), "{m}");
    }

    #[test]
    fn should_emit_bigint_footer_when_inout_i64_has_value() {
        let params =
            bound_to_slots(&[bp(ParamDirection::InOut, ParamValue::BigInt(9001))]).unwrap();
        assert_eq!(
            params.output_footer_values(),
            vec![ParamValue::BigInt(9001)]
        );
    }

    #[test]
    fn should_reject_output_binary_with_directed_prefix() {
        let err = bound_to_slots(&[bp(ParamDirection::Output, ParamValue::Binary(vec![0xAB]))])
            .err()
            .expect("output binary should fail");
        let OdbcError::ValidationError(m) = err else {
            panic!("expected ValidationError");
        };
        assert!(
            m.starts_with(super::ERR_PREFIX) && m.contains("binary_out_inout_not_implemented"),
            "{m}"
        );
    }
}

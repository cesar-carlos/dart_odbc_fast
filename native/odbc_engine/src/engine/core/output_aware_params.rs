//! Dynamic ODBC parameter binding (Input, Output, InOut) for mixed `?` lists.

use crate::error::{OdbcError, Result};
use crate::protocol::bound_param::{BoundParam, ParamDirection};
use crate::protocol::param_value::ParamValue;
use crate::protocol::param_values_to_strings;

use odbc_api::handles::Statement;
use odbc_api::ParameterCollection;
use odbc_api::{sys::ParamType, IntoParameter, Nullable};

#[cfg(windows)]
type TextBox = odbc_api::parameter::VarWCharBox;
#[cfg(not(windows))]
type TextBox = odbc_api::parameter::VarCharBox;

/// Owned parameter slots (one per `?` placeholder).
pub(crate) struct OutputAwareParams {
    pub slots: Vec<ParamSlot>,
}

/// Discriminated bind storage.
pub(crate) enum ParamSlot {
    InText(TextBox),
    OutI32(Nullable<i32>),
    OutI64(Nullable<i64>),
    InOutI32(Nullable<i32>),
    InOutI64(Nullable<i64>),
}

fn in_text_from_param_value(v: &ParamValue) -> Result<TextBox> {
    let o = param_values_to_strings(std::slice::from_ref(v))?
        .into_iter()
        .next()
        .ok_or_else(|| OdbcError::ValidationError("param_values_to_strings empty".to_string()))?;
    Ok(match o {
        None => TextBox::null(),
        Some(s) => s.as_str().into_parameter(),
    })
}

/// Maps [BoundParam] to ODBC bind slots.
pub(crate) fn bound_to_slots(bound: &[BoundParam]) -> Result<OutputAwareParams> {
    let mut slots = Vec::with_capacity(bound.len());
    for bp in bound {
        let slot = match (bp.direction, &bp.value) {
            (ParamDirection::Input, v) => ParamSlot::InText(in_text_from_param_value(v)?),
            (ParamDirection::Output, ParamValue::Null) => {
                ParamSlot::OutI32(Nullable::null())
            }
            (ParamDirection::Output, ParamValue::Integer(_)) => {
                ParamSlot::OutI32(Nullable::null())
            }
            (ParamDirection::Output, ParamValue::BigInt(_)) => {
                ParamSlot::OutI64(Nullable::null())
            }
            (ParamDirection::InOut, ParamValue::Integer(n)) => {
                ParamSlot::InOutI32(Nullable::new(*n))
            }
            (ParamDirection::InOut, ParamValue::BigInt(n)) => {
                ParamSlot::InOutI64(Nullable::new(*n))
            }
            (ParamDirection::InOut, ParamValue::Null) => {
                return Err(OdbcError::ValidationError(
                    "INOUT with ParamValue::Null is not supported".to_string(),
                ));
            }
            _ => {
                return Err(OdbcError::ValidationError(
                    "OUTPUT/INOUT in this release supports Integer, BigInt, and null-only OUTPUT markers"
                        .to_string(),
                ));
            }
        };
        slots.push(slot);
    }
    Ok(OutputAwareParams { slots })
}

impl OutputAwareParams {
    /// One [ParamValue] per `OUT` / `INOUT` slot, in `?` order (input slots not listed).
    pub fn output_footer_values(&self) -> Vec<ParamValue> {
        let mut v = Vec::new();
        for s in &self.slots {
            match s {
                ParamSlot::InText(_) => {}
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
            }
        }
        v
    }
}

unsafe impl ParameterCollection for OutputAwareParams {
    fn parameter_set_size(&self) -> usize {
        1
    }

    unsafe fn bind_parameters_to(
        &mut self,
        stmt: &mut impl Statement,
    ) -> std::result::Result<(), odbc_api::Error> {
        for (i, slot) in self.slots.iter_mut().enumerate() {
            let num = (i + 1) as u16;
            match slot {
                ParamSlot::InText(t) => {
                    unsafe { stmt.bind_input_parameter(num, t) }.into_result(stmt)?;
                }
                ParamSlot::OutI32(n) => {
                    unsafe { stmt.bind_parameter(num, ParamType::Output, n) }.into_result(stmt)?;
                }
                ParamSlot::OutI64(n) => {
                    unsafe { stmt.bind_parameter(num, ParamType::Output, n) }.into_result(stmt)?;
                }
                ParamSlot::InOutI32(n) => {
                    unsafe { stmt.bind_parameter(num, ParamType::InputOutput, n) }
                        .into_result(stmt)?;
                }
                ParamSlot::InOutI64(n) => {
                    unsafe { stmt.bind_parameter(num, ParamType::InputOutput, n) }
                        .into_result(stmt)?;
                }
            }
        }
        Ok(())
    }
}

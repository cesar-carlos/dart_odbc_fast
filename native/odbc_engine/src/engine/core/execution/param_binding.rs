use crate::error::{OdbcError, Result};
use crate::protocol::bound_param::BoundParam;
use crate::protocol::{has_null_param, param_values_to_input_params_with_inference, ParamValue};

/// Gate for Oracle-only ref-cursor binds before any connection I/O.
/// How [`super::ExecutionEngine::execute_query_with_params_inner`] routes positional params (no ODBC).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum QueryParamBindingPlan {
    DirectNoParams,
    InferenceExecute,
    PreparedNullAware,
    PreparedStandard,
}

pub(super) fn plan_query_param_binding(params: &[ParamValue]) -> Result<QueryParamBindingPlan> {
    if params.is_empty() {
        return Ok(QueryParamBindingPlan::DirectNoParams);
    }
    if has_null_param(params) {
        if param_values_to_input_params_with_inference(params)?.is_some() {
            return Ok(QueryParamBindingPlan::InferenceExecute);
        }
        return Ok(QueryParamBindingPlan::PreparedNullAware);
    }
    Ok(QueryParamBindingPlan::PreparedStandard)
}

/// How [`super::ExecutionEngine::execute_multi_result_with_params_inner`] routes params (no ODBC).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum MultiResultParamBindingPlan {
    InferencePrealloc,
    PreparedStandard,
    PreparedNullAware,
}

pub(super) fn plan_multi_result_param_binding(
    params: &[ParamValue],
) -> Result<MultiResultParamBindingPlan> {
    if param_values_to_input_params_with_inference(params)?.is_some() {
        return Ok(MultiResultParamBindingPlan::InferencePrealloc);
    }
    if has_null_param(params) {
        return Ok(MultiResultParamBindingPlan::PreparedNullAware);
    }
    Ok(MultiResultParamBindingPlan::PreparedStandard)
}

/// Converts positional params for the inference execute/prealloc paths.
/// Returns [`OdbcError::InternalError`] when the binding plan and conversion
/// disagree (regression guard against `.expect` on the inference branch).
pub(super) fn require_inference_input_params(
    params: &[ParamValue],
) -> Result<Vec<Box<dyn odbc_api::parameter::InputParameter>>> {
    param_values_to_input_params_with_inference(params)?.ok_or_else(|| {
        OdbcError::InternalError(
            "parameter binding plan mismatch: inference conversion returned None".to_string(),
        )
    })
}

pub(super) fn ensure_ref_cursor_oracle_only(
    bound: &[BoundParam],
    oracle_active: bool,
) -> Result<()> {
    use super::super::ref_cursor_oracle::bound_has_ref_cursor;

    if bound_has_ref_cursor(bound) && !oracle_active {
        return Err(OdbcError::ValidationError(
            "DIRECTED_PARAM|ref_cursor_out_oracle_only: ParamValue::RefCursorOut is \
             only supported with the Oracle ODBC driver; see \
             doc/notes/REF_CURSOR_ORACLE_ROADMAP.md"
                .to_string(),
        ));
    }
    Ok(())
}

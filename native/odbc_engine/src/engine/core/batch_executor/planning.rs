use crate::error::Result;
use crate::protocol::{has_null_param, param_values_to_input_params_with_inference, ParamValue};

use super::{BatchParam, BatchQuery};

/// Mirrors [`super::BatchExecutor::execute_batch`] direct vs optimized dispatch (no ODBC).
pub(crate) fn batch_query_uses_optimized_path(query: &BatchQuery) -> bool {
    !query.params.is_empty()
}

/// How [`super::BatchExecutor::execute_batch_optimized`] binds one param set before ODBC I/O.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BatchParamBindingPlan {
    Empty,
    InferenceDirect,
    PreparedStandard,
    PreparedNullAware,
}

pub(crate) fn plan_batch_param_binding(
    param_values: &[ParamValue],
) -> Result<BatchParamBindingPlan> {
    if param_values.is_empty() {
        return Ok(BatchParamBindingPlan::Empty);
    }
    if param_values_to_input_params_with_inference(param_values)?.is_some() {
        return Ok(BatchParamBindingPlan::InferenceDirect);
    }
    if has_null_param(param_values) {
        return Ok(BatchParamBindingPlan::PreparedNullAware);
    }
    Ok(BatchParamBindingPlan::PreparedStandard)
}

/// Mirrors [`super::BatchExecutor::execute_batch_optimized`] early return when there are no param sets.
pub(crate) fn should_skip_batch_optimized_execution(param_sets: &[Vec<BatchParam>]) -> bool {
    param_sets.is_empty()
}

/// Chunk count for `param_sets.chunks(effective_batch_size)` (no ODBC).
pub(crate) fn batch_param_set_chunk_count(
    param_sets_len: usize,
    effective_batch_size: usize,
) -> usize {
    if param_sets_len == 0 {
        0
    } else {
        param_sets_len.div_ceil(effective_batch_size.max(1))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ParamValue;

    #[test]
    fn should_plan_empty_param_values_for_prepared_execute_without_binds() {
        assert_eq!(
            plan_batch_param_binding(&[]).expect("empty plan"),
            BatchParamBindingPlan::Empty
        );
    }

    #[test]
    fn should_plan_homogeneous_integer_batch_for_inference_direct_path() {
        let params = vec![ParamValue::Integer(1), ParamValue::Integer(2)];
        assert_eq!(
            plan_batch_param_binding(&params).expect("integer inference plan"),
            BatchParamBindingPlan::InferenceDirect
        );
    }

    #[test]
    fn should_plan_mixed_integer_and_bigint_batch_for_inference_direct_path() {
        let params = vec![ParamValue::Integer(1), ParamValue::BigInt(2)];
        assert_eq!(
            plan_batch_param_binding(&params).expect("promoted inference plan"),
            BatchParamBindingPlan::InferenceDirect
        );
    }

    #[test]
    fn should_plan_non_null_standard_batch_without_inference() {
        let params = vec![ParamValue::String("a".to_string()), ParamValue::Integer(1)];
        assert_eq!(
            plan_batch_param_binding(&params).expect("standard plan"),
            BatchParamBindingPlan::PreparedStandard
        );
    }

    #[test]
    fn should_plan_null_batch_for_prepared_null_aware_path() {
        let params = vec![
            ParamValue::String("x".to_string()),
            ParamValue::Integer(1),
            ParamValue::Null,
        ];
        assert_eq!(
            plan_batch_param_binding(&params).expect("null-aware plan"),
            BatchParamBindingPlan::PreparedNullAware
        );
    }

    #[test]
    fn should_plan_homogeneous_nullable_integer_batch_for_inference() {
        let params = vec![ParamValue::Integer(1), ParamValue::Null];
        assert_eq!(
            plan_batch_param_binding(&params).expect("nullable integer inference"),
            BatchParamBindingPlan::InferenceDirect
        );
    }

    #[test]
    fn should_plan_bigint_only_batch_for_inference_direct_path() {
        let params = vec![ParamValue::BigInt(1), ParamValue::BigInt(2)];
        assert_eq!(
            plan_batch_param_binding(&params).expect("bigint inference"),
            BatchParamBindingPlan::InferenceDirect
        );
    }

    #[test]
    fn should_plan_string_only_batch_for_inference_direct_path() {
        let params = vec![ParamValue::String("a".to_string())];
        assert_eq!(
            plan_batch_param_binding(&params).expect("string inference"),
            BatchParamBindingPlan::InferenceDirect
        );
    }

    #[test]
    fn should_plan_all_null_batch_for_prepared_null_aware_path() {
        let params = vec![ParamValue::Null, ParamValue::Null];
        assert_eq!(
            plan_batch_param_binding(&params).expect("all-null plan"),
            BatchParamBindingPlan::PreparedNullAware
        );
    }

    #[test]
    fn should_skip_batch_optimized_when_param_sets_empty() {
        assert!(should_skip_batch_optimized_execution(&[]));
        assert!(!should_skip_batch_optimized_execution(&[vec![
            super::super::BatchParam::Integer(1)
        ]]));
    }

    #[test]
    fn should_count_batch_chunks_using_effective_batch_size_helper() {
        assert_eq!(batch_param_set_chunk_count(0, 10), 0);
        assert_eq!(batch_param_set_chunk_count(5, 2), 3);
        assert_eq!(batch_param_set_chunk_count(4, 2), 2);
        assert_eq!(batch_param_set_chunk_count(3, 0), 3);
    }

    #[test]
    fn should_plan_single_null_param_for_prepared_null_aware_path() {
        let params = vec![ParamValue::Null];
        assert_eq!(
            plan_batch_param_binding(&params).expect("single null plan"),
            BatchParamBindingPlan::PreparedNullAware
        );
    }

    #[test]
    fn should_plan_mixed_string_and_integer_for_prepared_standard_path() {
        let params = vec![ParamValue::String("a".to_string()), ParamValue::Integer(1)];
        assert_eq!(
            plan_batch_param_binding(&params).expect("mixed standard plan"),
            BatchParamBindingPlan::PreparedStandard
        );
    }

    #[test]
    fn should_route_direct_batch_query_without_optimized_path() {
        let query = BatchQuery::new("SELECT 1".to_string());
        assert!(!batch_query_uses_optimized_path(&query));
    }

    #[test]
    fn should_route_parameterized_batch_query_through_optimized_path() {
        let mut query = BatchQuery::new("SELECT ?".to_string());
        query.add_param(super::super::BatchParam::Integer(1));
        assert!(batch_query_uses_optimized_path(&query));
    }
}

mod execution;
mod inference;
mod planning;

use super::pipeline::QueryPipeline;
use crate::error::{OdbcError, Result};
use crate::protocol::{
    param_values_to_input_params, param_values_to_input_params_with_descriptions,
    param_values_to_input_params_with_inference, ParamValue,
};
use inference::batch_param_to_param_value;
use odbc_api::handles::ParameterDescription;
use odbc_api::Connection;

pub(crate) use planning::{
    batch_param_set_chunk_count, batch_query_uses_optimized_path, plan_batch_param_binding,
    should_skip_batch_optimized_execution, BatchParamBindingPlan,
};
use std::sync::Arc;

pub struct BatchQuery {
    sql: String,
    params: Vec<BatchParam>,
}

pub enum BatchParam {
    String(String),
    Integer(i32),
    BigInt(i64),
    Null,
}

impl BatchQuery {
    pub fn new(sql: String) -> Self {
        Self {
            sql,
            params: Vec::new(),
        }
    }

    pub fn add_param(&mut self, param: BatchParam) {
        self.params.push(param);
    }
}

pub struct BatchExecutor {
    pipeline: Arc<QueryPipeline>,
    batch_size: usize,
}

impl BatchExecutor {
    pub fn new(cache_size: usize, batch_size: usize) -> Self {
        Self {
            pipeline: Arc::new(QueryPipeline::new(cache_size)),
            batch_size,
        }
    }

    pub fn batch_size(&self) -> usize {
        self.batch_size
    }

    pub(crate) fn effective_batch_size(&self) -> usize {
        self.batch_size.max(1)
    }

    pub fn execute_batch(
        &self,
        conn: &Connection<'static>,
        queries: Vec<BatchQuery>,
    ) -> Result<Vec<Vec<u8>>> {
        let mut results = Vec::new();

        for query in queries {
            if batch_query_uses_optimized_path(&query) {
                let mut result =
                    self.execute_batch_optimized(conn, &query.sql, vec![query.params])?;
                results.append(&mut result);
            } else {
                let result = self.pipeline.execute_direct(conn, &query.sql)?;
                results.push(result);
            }
        }

        Ok(results)
    }

    pub fn execute_batch_optimized(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        param_sets: Vec<Vec<BatchParam>>,
    ) -> Result<Vec<Vec<u8>>> {
        let mut results = Vec::new();
        if should_skip_batch_optimized_execution(&param_sets) {
            return Ok(results);
        }

        let batch_size = self.effective_batch_size();
        let chunk_limit = batch_param_set_chunk_count(param_sets.len(), batch_size);
        let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;
        let mut parameter_descriptions: Option<Vec<ParameterDescription>> = None;

        for params_chunk in param_sets.chunks(batch_size).take(chunk_limit) {
            for param_set in params_chunk {
                let param_values: Vec<ParamValue> =
                    param_set.iter().map(batch_param_to_param_value).collect();

                match plan_batch_param_binding(&param_values)? {
                    BatchParamBindingPlan::InferenceDirect => {
                        let parameters =
                            param_values_to_input_params_with_inference(&param_values)?
                                .ok_or_else(|| {
                                    OdbcError::InternalError(
                                    "plan_batch_param_binding promised inference but binding failed"
                                        .to_string(),
                                )
                                })?;
                        let encoded = self.execute_direct_param_set(conn, sql, parameters)?;
                        results.push(encoded);
                        continue;
                    }
                    BatchParamBindingPlan::Empty => {
                        let encoded = self.execute_prepared_and_encode(&mut stmt, ())?;
                        results.push(encoded);
                    }
                    BatchParamBindingPlan::PreparedNullAware => {
                        let descriptions = match parameter_descriptions.as_ref() {
                            Some(descriptions) => descriptions,
                            None => {
                                let collected = stmt
                                    .parameter_descriptions()
                                    .map_err(OdbcError::from)?
                                    .collect::<std::result::Result<Vec<_>, _>>()
                                    .map_err(OdbcError::from)?;
                                parameter_descriptions.insert(collected)
                            }
                        };
                        let parameters = param_values_to_input_params_with_descriptions(
                            &param_values,
                            descriptions,
                        )?;
                        let encoded =
                            self.execute_prepared_and_encode(&mut stmt, parameters.as_slice())?;
                        results.push(encoded);
                    }
                    BatchParamBindingPlan::PreparedStandard => {
                        let parameters = param_values_to_input_params(&param_values)?;
                        let encoded =
                            self.execute_prepared_and_encode(&mut stmt, parameters.as_slice())?;
                        results.push(encoded);
                    }
                }
            }
        }

        Ok(results)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{decode_multi, encode_row_count_only, MultiResultItem, ParamValue};

    #[test]
    fn test_batch_query_new() {
        let query = BatchQuery::new("SELECT 1".to_string());
        assert_eq!(query.sql, "SELECT 1");
        assert!(query.params.is_empty());
    }

    #[test]
    fn test_batch_query_add_param() {
        let mut query = BatchQuery::new("SELECT ?".to_string());

        query.add_param(BatchParam::String("test".to_string()));
        assert_eq!(query.params.len(), 1);

        query.add_param(BatchParam::Integer(42));
        assert_eq!(query.params.len(), 2);

        query.add_param(BatchParam::BigInt(123456789));
        assert_eq!(query.params.len(), 3);

        query.add_param(BatchParam::Null);
        assert_eq!(query.params.len(), 4);
    }

    #[test]
    fn test_batch_executor_new() {
        let executor = BatchExecutor::new(100, 10);
        assert_eq!(executor.batch_size(), 10);
    }

    #[test]
    fn test_batch_executor_batch_size() {
        let executor1 = BatchExecutor::new(50, 5);
        assert_eq!(executor1.batch_size(), 5);

        let executor2 = BatchExecutor::new(200, 20);
        assert_eq!(executor2.batch_size(), 20);
    }

    #[test]
    fn test_batch_param_variants() {
        let string_param = BatchParam::String("hello".to_string());
        match string_param {
            BatchParam::String(s) => assert_eq!(s, "hello"),
            _ => panic!("Expected String variant"),
        }

        let int_param = BatchParam::Integer(42);
        match int_param {
            BatchParam::Integer(i) => assert_eq!(i, 42),
            _ => panic!("Expected Integer variant"),
        }

        let bigint_param = BatchParam::BigInt(123456789);
        match bigint_param {
            BatchParam::BigInt(b) => assert_eq!(b, 123456789),
            _ => panic!("Expected BigInt variant"),
        }

        let null_param = BatchParam::Null;
        match null_param {
            BatchParam::Null => {}
            _ => panic!("Expected Null variant"),
        }
    }

    #[test]
    fn test_batch_query_multiple_params() {
        let mut query = BatchQuery::new("INSERT INTO test VALUES (?, ?, ?)".to_string());
        query.add_param(BatchParam::String("value1".to_string()));
        query.add_param(BatchParam::Integer(100));
        query.add_param(BatchParam::BigInt(999999999i64));

        assert_eq!(query.params.len(), 3);
        assert_eq!(query.sql, "INSERT INTO test VALUES (?, ?, ?)");
    }

    #[test]
    fn test_batch_query_empty_sql() {
        let query = BatchQuery::new(String::new());
        assert_eq!(query.sql, "");
        assert!(query.params.is_empty());
    }

    #[test]
    fn test_batch_executor_different_cache_sizes() {
        let executor1 = BatchExecutor::new(0, 1);
        assert_eq!(executor1.batch_size(), 1);

        let executor2 = BatchExecutor::new(1000, 100);
        assert_eq!(executor2.batch_size(), 100);
    }

    #[test]
    fn test_batch_param_string_with_special_chars() {
        let param = BatchParam::String("test'\"\\\n\t".to_string());
        match param {
            BatchParam::String(s) => assert_eq!(s, "test'\"\\\n\t"),
            _ => panic!("Expected String variant"),
        }
    }

    #[test]
    fn test_batch_param_integer_boundaries() {
        let min_param = BatchParam::Integer(i32::MIN);
        match min_param {
            BatchParam::Integer(i) => assert_eq!(i, i32::MIN),
            _ => panic!("Expected Integer variant"),
        }

        let max_param = BatchParam::Integer(i32::MAX);
        match max_param {
            BatchParam::Integer(i) => assert_eq!(i, i32::MAX),
            _ => panic!("Expected Integer variant"),
        }
    }

    #[test]
    fn test_batch_param_bigint_boundaries() {
        let min_param = BatchParam::BigInt(i64::MIN);
        match min_param {
            BatchParam::BigInt(b) => assert_eq!(b, i64::MIN),
            _ => panic!("Expected BigInt variant"),
        }

        let max_param = BatchParam::BigInt(i64::MAX);
        match max_param {
            BatchParam::BigInt(b) => assert_eq!(b, i64::MAX),
            _ => panic!("Expected BigInt variant"),
        }
    }

    #[test]
    fn test_batch_query_sql_with_whitespace() {
        let query = BatchQuery::new("  SELECT * FROM table  ".to_string());
        assert_eq!(query.sql, "  SELECT * FROM table  ");
    }

    #[test]
    fn test_batch_executor_zero_batch_size() {
        let executor = BatchExecutor::new(10, 0);
        assert_eq!(executor.batch_size(), 0);
        assert_eq!(executor.effective_batch_size(), 1);
    }

    #[test]
    fn test_batch_executor_effective_batch_size_preserves_non_zero() {
        let executor = BatchExecutor::new(10, 25);
        assert_eq!(executor.effective_batch_size(), 25);
    }

    #[test]
    fn test_batch_param_conversion() {
        match batch_param_to_param_value(&BatchParam::String("hello".to_string())) {
            ParamValue::String(value) => assert_eq!(value, "hello"),
            _ => panic!("Expected String value"),
        }

        match batch_param_to_param_value(&BatchParam::Integer(42)) {
            ParamValue::Integer(value) => assert_eq!(value, 42),
            _ => panic!("Expected Integer value"),
        }

        match batch_param_to_param_value(&BatchParam::BigInt(123456789)) {
            ParamValue::BigInt(value) => assert_eq!(value, 123456789),
            _ => panic!("Expected BigInt value"),
        }

        match batch_param_to_param_value(&BatchParam::Null) {
            ParamValue::Null => {}
            _ => panic!("Expected Null value"),
        }
    }

    #[test]
    fn should_clone_batch_param_strings_when_converting_to_param_value() {
        let param = BatchParam::String("copy-me".to_string());
        match batch_param_to_param_value(&param) {
            ParamValue::String(value) => assert_eq!(value, "copy-me"),
            _ => panic!("expected String ParamValue"),
        }
        match param {
            BatchParam::String(original) => assert_eq!(original, "copy-me"),
            _ => panic!("original BatchParam unchanged"),
        }
    }

    #[test]
    fn should_chunk_param_sets_using_effective_batch_size() {
        let executor = BatchExecutor::new(10, 2);
        let param_sets: Vec<Vec<BatchParam>> =
            (0..5).map(|i| vec![BatchParam::Integer(i)]).collect();
        let chunk_count = param_sets.chunks(executor.effective_batch_size()).count();
        assert_eq!(chunk_count, 3);
    }

    #[test]
    fn should_treat_zero_batch_size_as_single_row_chunks() {
        let executor = BatchExecutor::new(10, 0);
        let param_sets = [vec![BatchParam::Integer(1)], vec![BatchParam::Integer(2)]];
        let chunk_count = param_sets.chunks(executor.effective_batch_size()).count();
        assert_eq!(chunk_count, 2);
    }

    #[test]
    fn should_distinguish_direct_vs_parameterized_batch_queries() {
        let direct = BatchQuery::new("SELECT 1".to_string());
        let mut parameterized = BatchQuery::new("SELECT ?".to_string());
        parameterized.add_param(BatchParam::Integer(1));
        assert!(direct.params.is_empty());
        assert!(!parameterized.params.is_empty());
    }

    #[test]
    fn should_route_direct_batch_query_without_optimized_path() {
        let query = BatchQuery::new("SELECT 1".to_string());
        assert!(!batch_query_uses_optimized_path(&query));
    }

    #[test]
    fn should_route_parameterized_batch_query_through_optimized_path() {
        let mut query = BatchQuery::new("SELECT ?".to_string());
        query.add_param(BatchParam::Integer(1));
        assert!(batch_query_uses_optimized_path(&query));
    }

    #[test]
    fn should_map_all_batch_param_variants_to_param_values() {
        let cases = [
            (
                BatchParam::String("s".to_string()),
                ParamValue::String("s".to_string()),
            ),
            (BatchParam::Integer(7), ParamValue::Integer(7)),
            (BatchParam::BigInt(9), ParamValue::BigInt(9)),
            (BatchParam::Null, ParamValue::Null),
        ];
        for (batch, expected) in cases {
            assert_eq!(batch_param_to_param_value(&batch), expected);
        }
    }

    #[test]
    fn encode_row_count_only_round_trips_through_multi_decoder() {
        let wire = encode_row_count_only(99);
        let items = decode_multi(&wire).expect("decode");
        assert_eq!(items, vec![MultiResultItem::RowCount(99)]);
    }

    #[test]
    fn should_route_multiple_batch_queries_by_param_presence() {
        let direct = BatchQuery::new("DELETE FROM t".to_string());
        let mut parameterized = BatchQuery::new("INSERT INTO t VALUES (?)".to_string());
        parameterized.add_param(BatchParam::Integer(1));
        assert!(!batch_query_uses_optimized_path(&direct));
        assert!(batch_query_uses_optimized_path(&parameterized));
    }

    #[test]
    fn should_align_chunk_helper_with_chunks_iterator() {
        let executor = BatchExecutor::new(10, 3);
        let param_sets: Vec<Vec<BatchParam>> =
            (0..7).map(|i| vec![BatchParam::Integer(i)]).collect();
        let effective = executor.effective_batch_size();
        assert_eq!(
            batch_param_set_chunk_count(param_sets.len(), effective),
            param_sets.chunks(effective).count()
        );
    }
}

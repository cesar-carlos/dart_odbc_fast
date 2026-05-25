use super::pipeline::QueryPipeline;
use crate::engine::cell_reader::CellReader;
use crate::engine::sqlserver_json::coalesce_for_json_rows;
use crate::error::{OdbcError, Result};
use crate::protocol::{
    has_null_param, param_values_to_input_params, param_values_to_input_params_with_descriptions,
    param_values_to_input_params_with_inference, OdbcType, ParamValue, RowBuffer, RowBufferEncoder,
};
use odbc_api::handles::{AsStatementRef, ParameterDescription};
use odbc_api::parameter::InputParameter;
use odbc_api::{Connection, Cursor, ParameterCollectionRef, Prepared, ResultSetMetadata};
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

    fn effective_batch_size(&self) -> usize {
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
                                .expect("plan_batch_param_binding guarantees inference path");
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

    fn execute_prepared_and_encode<S, P>(
        &self,
        stmt: &mut Prepared<S>,
        params: P,
    ) -> Result<Vec<u8>>
    where
        S: AsStatementRef,
        P: ParameterCollectionRef,
    {
        let mut cursor = stmt.execute(params).map_err(OdbcError::from)?;
        if let Some(mut c) = cursor.take() {
            return self.encode_result_cursor(&mut c);
        }
        drop(cursor);
        let row_count = stmt.row_count().map_err(OdbcError::from)?.unwrap_or(0) as i64;
        Ok(crate::protocol::encode_row_count_only(row_count))
    }

    fn encode_result_cursor<C>(&self, cursor: &mut C) -> Result<Vec<u8>>
    where
        C: Cursor + ResultSetMetadata,
    {
        let mut row_buffer = RowBuffer::new();
        let cols_i16 = cursor.num_result_cols().map_err(OdbcError::from)?;
        let cols_u16: u16 = cols_i16
            .try_into()
            .map_err(|_| OdbcError::InternalError("Invalid column count".to_string()))?;
        let cols_usize: usize = cols_u16.into();
        let mut column_types: Vec<OdbcType> = Vec::with_capacity(cols_usize);

        for col_idx in 1..=cols_u16 {
            let col_name = cursor.col_name(col_idx).map_err(OdbcError::from)?;
            let col_type = cursor.col_data_type(col_idx).map_err(OdbcError::from)?;
            let sql_type_code = OdbcType::sql_type_code_from_data_type(&col_type);
            let odbc_type = OdbcType::from_odbc_sql_type(sql_type_code);
            row_buffer.add_column(col_name.to_string(), odbc_type);
            column_types.push(odbc_type);
        }

        let mut cell_reader = CellReader::new();
        while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
            let mut row_data = Vec::with_capacity(column_types.len());
            for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                let col_number: u16 = (col_idx + 1)
                    .try_into()
                    .map_err(|_| OdbcError::InternalError("Invalid column number".to_string()))?;
                let cell_data = cell_reader.read_cell_bytes(&mut row, col_number, odbc_type)?;
                row_data.push(cell_data);
            }
            row_buffer.add_row(row_data);
        }

        coalesce_for_json_rows(&mut row_buffer);
        RowBufferEncoder::encode_result(&row_buffer)
    }

    fn execute_direct_param_set(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        parameters: Vec<Box<dyn InputParameter>>,
    ) -> Result<Vec<u8>> {
        let mut prealloc = conn.preallocate().map_err(OdbcError::from)?;
        let mut cursor = if parameters.is_empty() {
            prealloc.execute(sql, ()).map_err(OdbcError::from)?
        } else {
            prealloc
                .execute(sql, parameters.as_slice())
                .map_err(OdbcError::from)?
        };

        let mut taken = cursor.take();
        if taken.is_none() {
            drop(taken);
            drop(cursor);
            let row_count = prealloc.row_count().map_err(OdbcError::from)?.unwrap_or(0) as i64;
            return Ok(crate::protocol::encode_row_count_only(row_count));
        }

        let Some(mut c) = taken.take() else {
            return Err(OdbcError::InternalError(
                "Expected result cursor after successful execute".to_string(),
            ));
        };
        let mut row_buffer = RowBuffer::new();
        let cols_i16 = c.num_result_cols().map_err(OdbcError::from)?;
        let cols_u16: u16 = cols_i16
            .try_into()
            .map_err(|_| OdbcError::InternalError("Invalid column count".to_string()))?;
        let cols_usize: usize = cols_u16.into();
        let mut column_types: Vec<OdbcType> = Vec::with_capacity(cols_usize);

        for col_idx in 1..=cols_u16 {
            let col_name = c.col_name(col_idx).map_err(OdbcError::from)?;
            let col_type = c.col_data_type(col_idx).map_err(OdbcError::from)?;
            let sql_type_code = OdbcType::sql_type_code_from_data_type(&col_type);
            let odbc_type = OdbcType::from_odbc_sql_type(sql_type_code);
            row_buffer.add_column(col_name.to_string(), odbc_type);
            column_types.push(odbc_type);
        }

        let mut cell_reader = CellReader::new();
        while let Some(mut row) = c.next_row().map_err(OdbcError::from)? {
            let mut row_data = Vec::with_capacity(column_types.len());
            for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                let col_number: u16 = (col_idx + 1)
                    .try_into()
                    .map_err(|_| OdbcError::InternalError("Invalid column number".to_string()))?;
                let cell_data = cell_reader.read_cell_bytes(&mut row, col_number, odbc_type)?;
                row_data.push(cell_data);
            }
            row_buffer.add_row(row_data);
        }

        coalesce_for_json_rows(&mut row_buffer);
        RowBufferEncoder::encode_result(&row_buffer)
    }
}

fn batch_param_to_param_value(param: &BatchParam) -> ParamValue {
    match param {
        BatchParam::String(s) => ParamValue::String(s.clone()),
        BatchParam::Integer(n) => ParamValue::Integer(*n),
        BatchParam::BigInt(n) => ParamValue::BigInt(*n),
        BatchParam::Null => ParamValue::Null,
    }
}

/// How [`BatchExecutor::execute_batch_optimized`] binds one param set before ODBC I/O.
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

/// Mirrors [`BatchExecutor::execute_batch`] direct vs optimized dispatch (no ODBC).
pub(crate) fn batch_query_uses_optimized_path(query: &BatchQuery) -> bool {
    !query.params.is_empty()
}

/// Mirrors [`BatchExecutor::execute_batch_optimized`] early return when there are no param sets.
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
    fn should_skip_batch_optimized_when_param_sets_empty() {
        assert!(should_skip_batch_optimized_execution(&[]));
        assert!(!should_skip_batch_optimized_execution(&[vec![
            BatchParam::Integer(1)
        ]]));
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
    fn encode_row_count_only_round_trips_through_multi_decoder() {
        use crate::protocol::{decode_multi, encode_row_count_only, MultiResultItem};
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

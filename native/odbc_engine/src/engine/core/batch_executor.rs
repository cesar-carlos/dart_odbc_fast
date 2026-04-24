use super::pipeline::QueryPipeline;
use crate::engine::cell_reader::CellReader;
use crate::engine::sqlserver_json::coalesce_for_json_rows;
use crate::error::{OdbcError, Result};
use crate::protocol::{param_values_to_strings, OdbcType, ParamValue, RowBuffer, RowBufferEncoder};
use odbc_api::{Connection, Cursor, IntoParameter, ResultSetMetadata};
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
            if query.params.is_empty() {
                let result = self.pipeline.execute_direct(conn, &query.sql)?;
                results.push(result);
            } else {
                let mut result =
                    self.execute_batch_optimized(conn, &query.sql, vec![query.params])?;
                results.append(&mut result);
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
        if param_sets.is_empty() {
            return Ok(results);
        }

        let batch_size = self.effective_batch_size();
        let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;

        for params_chunk in param_sets.chunks(batch_size) {
            for param_set in params_chunk {
                let param_values: Vec<ParamValue> =
                    param_set.iter().map(batch_param_to_param_value).collect();

                let optional_strings = param_values_to_strings(&param_values)?;

                let mut cursor = match optional_strings.len() {
                    0 => stmt.execute(()).map_err(OdbcError::from)?,
                    1 => {
                        let p0 = optional_strings[0].as_deref().into_parameter();
                        stmt.execute((&p0,)).map_err(OdbcError::from)?
                    }
                    2 => {
                        let p0 = optional_strings[0].as_deref().into_parameter();
                        let p1 = optional_strings[1].as_deref().into_parameter();
                        stmt.execute((&p0, &p1)).map_err(OdbcError::from)?
                    }
                    3 => {
                        let p0 = optional_strings[0].as_deref().into_parameter();
                        let p1 = optional_strings[1].as_deref().into_parameter();
                        let p2 = optional_strings[2].as_deref().into_parameter();
                        stmt.execute((&p0, &p1, &p2)).map_err(OdbcError::from)?
                    }
                    4 => {
                        let p0 = optional_strings[0].as_deref().into_parameter();
                        let p1 = optional_strings[1].as_deref().into_parameter();
                        let p2 = optional_strings[2].as_deref().into_parameter();
                        let p3 = optional_strings[3].as_deref().into_parameter();
                        stmt.execute((&p0, &p1, &p2, &p3))
                            .map_err(OdbcError::from)?
                    }
                    5 => {
                        let p0 = optional_strings[0].as_deref().into_parameter();
                        let p1 = optional_strings[1].as_deref().into_parameter();
                        let p2 = optional_strings[2].as_deref().into_parameter();
                        let p3 = optional_strings[3].as_deref().into_parameter();
                        let p4 = optional_strings[4].as_deref().into_parameter();
                        stmt.execute((&p0, &p1, &p2, &p3, &p4))
                            .map_err(OdbcError::from)?
                    }
                    n => {
                        return Err(OdbcError::ValidationError(format!(
                            "At most 5 parameters supported in batch, got {}",
                            n
                        )));
                    }
                };

                let mut taken = cursor.take();
                let encoded = if taken.is_none() {
                    drop(taken);
                    drop(cursor);
                    let row_count = stmt.row_count().map_err(OdbcError::from)?.unwrap_or(0) as i64;
                    crate::protocol::encode_multi(&[crate::protocol::MultiResultItem::RowCount(
                        row_count,
                    )])
                } else {
                    let Some(mut c) = taken.take() else {
                        return Err(OdbcError::InternalError(
                            "Expected result cursor after successful execute".to_string(),
                        ));
                    };
                    let mut row_buffer = RowBuffer::new();
                    let cols_i16 = c.num_result_cols().map_err(OdbcError::from)?;
                    let cols_u16: u16 = cols_i16.try_into().map_err(|_| {
                        OdbcError::InternalError("Invalid column count".to_string())
                    })?;
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
                            let col_number: u16 = (col_idx + 1).try_into().map_err(|_| {
                                OdbcError::InternalError("Invalid column number".to_string())
                            })?;
                            let cell_data =
                                cell_reader.read_cell_bytes(&mut row, col_number, odbc_type)?;
                            row_data.push(cell_data);
                        }
                        row_buffer.add_row(row_data);
                    }

                    coalesce_for_json_rows(&mut row_buffer);
                    RowBufferEncoder::encode(&row_buffer)
                };

                results.push(encoded);
            }
        }

        Ok(results)
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
}

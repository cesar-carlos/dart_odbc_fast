use super::array_binding::ArrayBinding;
use crate::error::{OdbcError, Result};
use crate::pool::ConnectionPool;
use rayon::prelude::*;
use std::sync::Arc;

const DEFAULT_BATCH_SIZE: usize = 10_000;

pub(crate) fn validate_i32_parallel_input(columns: &[&str], data: &[Vec<i32>]) -> Result<()> {
    let n_cols = columns.len();
    if data.len() != n_cols {
        return Err(OdbcError::ValidationError(
            "data length must match columns length".to_string(),
        ));
    }
    if data.is_empty() {
        return Ok(());
    }
    let n_rows = data[0].len();
    for col in data.iter().skip(1) {
        if col.len() != n_rows {
            return Err(OdbcError::ValidationError(
                "all columns must have same row count".to_string(),
            ));
        }
    }
    Ok(())
}

pub struct ParallelBulkInsert {
    pool: Arc<ConnectionPool>,
    batch_size: usize,
    parallelism: usize,
}

impl ParallelBulkInsert {
    pub fn new(pool: Arc<ConnectionPool>, parallelism: usize) -> Self {
        Self {
            pool,
            batch_size: DEFAULT_BATCH_SIZE,
            parallelism: parallelism.max(1),
        }
    }

    pub fn with_batch_size(mut self, batch_size: usize) -> Self {
        self.batch_size = batch_size.max(1);
        self
    }

    pub fn batch_size(&self) -> usize {
        self.batch_size
    }

    pub fn parallelism(&self) -> usize {
        self.parallelism
    }

    pub fn insert_i32_parallel(
        &self,
        table: &str,
        columns: &[&str],
        data: Vec<Vec<i32>>,
    ) -> Result<usize> {
        validate_i32_parallel_input(columns, &data)?;
        let n_cols = columns.len();
        if n_cols == 0 {
            return Ok(0);
        }
        let n_rows = data[0].len();
        if n_rows == 0 {
            return Ok(0);
        }

        let chunk_size = n_rows.div_ceil(self.parallelism).max(1).min(n_rows);
        let mut chunks: Vec<Vec<Vec<i32>>> = Vec::new();
        for start in (0..n_rows).step_by(chunk_size) {
            let end = (start + chunk_size).min(n_rows);
            let chunk: Vec<Vec<i32>> = data.iter().map(|col| col[start..end].to_vec()).collect();
            chunks.push(chunk);
        }

        let pool = Arc::clone(&self.pool);
        let table = Arc::new(table.to_string());
        let columns: Arc<Vec<String>> =
            Arc::new(columns.iter().map(|s| (*s).to_string()).collect());
        let batch_size = self.batch_size;

        let results: Vec<Result<usize>> = chunks
            .into_par_iter()
            .map(|chunk| {
                let conn = pool.get()?;
                let odbc_conn = conn.get_connection();
                let ab = ArrayBinding::new(batch_size);
                let cols: Vec<&str> = columns.iter().map(String::as_str).collect();
                ab.bulk_insert_i32(odbc_conn, &table, &cols, &chunk)
            })
            .collect();

        let mut total = 0_usize;
        for r in results {
            total += r?;
        }
        Ok(total)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::OdbcError;
    use crate::test_helpers::load_dotenv;

    #[test]
    fn test_validate_i32_parallel_input_mismatched_columns() {
        let columns = ["a", "b"];
        let data: Vec<Vec<i32>> = vec![vec![1], vec![2], vec![3]];
        let r = validate_i32_parallel_input(&columns, &data);
        assert!(r.is_err());
        assert!(matches!(r.unwrap_err(), OdbcError::ValidationError(_)));
    }

    #[test]
    fn test_validate_i32_parallel_input_different_column_lengths() {
        let columns = ["a", "b"];
        let data: Vec<Vec<i32>> = vec![vec![1, 2], vec![3]];
        let r = validate_i32_parallel_input(&columns, &data);
        assert!(r.is_err());
        assert!(matches!(r.unwrap_err(), OdbcError::ValidationError(_)));
    }

    #[test]
    fn test_validate_i32_parallel_input_zero_rows() {
        let columns = ["a", "b"];
        let data: Vec<Vec<i32>> = vec![vec![], vec![]];
        let r = validate_i32_parallel_input(&columns, &data);
        assert!(r.is_ok());
    }

    #[test]
    fn test_validate_i32_parallel_input_valid() {
        let columns = ["a", "b"];
        let data: Vec<Vec<i32>> = vec![vec![1, 2, 3], vec![4, 5, 6]];
        let r = validate_i32_parallel_input(&columns, &data);
        assert!(r.is_ok());
    }

    #[test]
    fn test_default_batch_size() {
        assert_eq!(DEFAULT_BATCH_SIZE, 10_000);
    }

    #[test]
    #[ignore]
    fn test_parallel_bulk_insert_new() {
        load_dotenv();
        let conn_str = std::env::var("ODBC_TEST_DSN").expect("ODBC_TEST_DSN not set");
        let pool = Arc::new(ConnectionPool::new(&conn_str, 4).unwrap());
        let pbi = ParallelBulkInsert::new(pool, 4);
        assert_eq!(pbi.parallelism(), 4);
        assert_eq!(pbi.batch_size(), DEFAULT_BATCH_SIZE);
    }

    #[test]
    #[ignore]
    fn test_parallel_bulk_insert_with_batch_size() {
        load_dotenv();
        let conn_str = std::env::var("ODBC_TEST_DSN").expect("ODBC_TEST_DSN not set");
        let pool = Arc::new(ConnectionPool::new(&conn_str, 2).unwrap());
        let pbi = ParallelBulkInsert::new(pool, 2).with_batch_size(5_000);
        assert_eq!(pbi.batch_size(), 5_000);
    }
}

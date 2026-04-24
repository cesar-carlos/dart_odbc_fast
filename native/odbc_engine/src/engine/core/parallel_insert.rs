use super::array_binding::ArrayBinding;
use crate::error::{OdbcError, Result};
use crate::pool::ConnectionPool;
use rayon::prelude::*;
use std::ops::Range;
use std::sync::Arc;

const DEFAULT_BATCH_SIZE: usize = 10_000;

/// Atomicity contract for `insert_i32_parallel`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ParallelMode {
    /// Each chunk runs in its own connection with autocommit. A mid-flight
    /// failure leaves committed chunks in the database (not atomic).
    /// Fastest, but caller must own compensation/retry logic.
    #[default]
    Independent,
    /// Each chunk runs inside its own transaction (`BEGIN`/`COMMIT`).
    /// On failure, that chunk is rolled back; other chunks already committed
    /// stay committed (per-chunk atomicity, not global).
    PerChunkTransactional,
}

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
    mode: ParallelMode,
}

impl ParallelBulkInsert {
    pub fn new(pool: Arc<ConnectionPool>, parallelism: usize) -> Self {
        Self {
            pool,
            batch_size: DEFAULT_BATCH_SIZE,
            parallelism: parallelism.max(1),
            mode: ParallelMode::Independent,
        }
    }

    pub fn with_batch_size(mut self, batch_size: usize) -> Self {
        self.batch_size = batch_size.max(1);
        self
    }

    /// Configure the atomicity contract. See [`ParallelMode`] for trade-offs.
    pub fn with_mode(mut self, mode: ParallelMode) -> Self {
        self.mode = mode;
        self
    }

    pub fn batch_size(&self) -> usize {
        self.batch_size
    }

    pub fn parallelism(&self) -> usize {
        self.parallelism
    }

    pub fn mode(&self) -> ParallelMode {
        self.mode
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

        let ranges = chunk_ranges(n_rows, self.parallelism);

        let pool = Arc::clone(&self.pool);
        let data = Arc::new(data);
        let table = Arc::new(table.to_string());
        let columns: Arc<Vec<String>> =
            Arc::new(columns.iter().map(|s| (*s).to_string()).collect());
        let batch_size = self.batch_size;
        let mode = self.mode;

        let results: Vec<Result<usize>> = ranges
            .into_par_iter()
            .map(|range| {
                let chunk = build_i32_chunk(&data, range);
                let ab = ArrayBinding::new(batch_size);
                let cols: Vec<&str> = columns.iter().map(String::as_str).collect();

                match mode {
                    ParallelMode::Independent => {
                        let conn = pool.get()?;
                        let odbc_conn = conn.get_connection();
                        ab.bulk_insert_i32(odbc_conn, &table, &cols, &chunk)
                    }
                    ParallelMode::PerChunkTransactional => {
                        // Per-chunk atomicity: open a transaction on the borrowed
                        // connection, run the insert, then commit or rollback.
                        // Note: `bulk_insert_i32` borrows the connection
                        // immutably while we need a brief mutable borrow for
                        // autocommit toggles. We perform them around the call.
                        let mut conn_mut = pool.get()?;
                        conn_mut
                            .get_connection_mut()
                            .set_autocommit(false)
                            .map_err(OdbcError::from)?;
                        let result =
                            ab.bulk_insert_i32(conn_mut.get_connection(), &table, &cols, &chunk);
                        match result {
                            Ok(n) => {
                                conn_mut
                                    .get_connection_mut()
                                    .commit()
                                    .map_err(OdbcError::from)?;
                                let _ = conn_mut.get_connection_mut().set_autocommit(true);
                                Ok(n)
                            }
                            Err(e) => {
                                if let Err(re) = conn_mut.get_connection_mut().rollback() {
                                    log::error!("ParallelBulkInsert: rollback after failure: {re}");
                                }
                                let _ = conn_mut.get_connection_mut().set_autocommit(true);
                                Err(e)
                            }
                        }
                    }
                }
            })
            .collect();

        let mut total = 0_usize;
        let mut errors: Vec<(usize, String)> = Vec::new();
        for (chunk_idx, r) in results.into_iter().enumerate() {
            match r {
                Ok(n) => total += n,
                Err(e) => errors.push((chunk_idx, e.to_string())),
            }
        }

        collect_partial_failure(total, errors)
    }
}

fn chunk_ranges(row_count: usize, parallelism: usize) -> Vec<Range<usize>> {
    if row_count == 0 {
        return Vec::new();
    }

    let chunk_size = row_count.div_ceil(parallelism.max(1)).max(1).min(row_count);
    (0..row_count)
        .step_by(chunk_size)
        .map(|start| start..(start + chunk_size).min(row_count))
        .collect()
}

fn build_i32_chunk(data: &[Vec<i32>], range: Range<usize>) -> Vec<Vec<i32>> {
    data.iter()
        .map(|col| col[range.start..range.end].to_vec())
        .collect()
}

fn collect_partial_failure(total: usize, errors: Vec<(usize, String)>) -> Result<usize> {
    if errors.is_empty() {
        return Ok(total);
    }

    let detail = errors
        .iter()
        .map(|(idx, err)| format!("chunk[{}]: {}", idx, err))
        .collect::<Vec<_>>()
        .join("; ");
    Err(OdbcError::BulkPartialFailure {
        rows_inserted_before_failure: total,
        failed_chunks: errors.len(),
        detail,
    })
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
    fn test_chunk_ranges_respect_parallelism() {
        let ranges = chunk_ranges(10, 3);
        assert_eq!(ranges, vec![0..4, 4..8, 8..10]);
    }

    #[test]
    fn test_chunk_ranges_zero_rows() {
        assert!(chunk_ranges(0, 4).is_empty());
    }

    #[test]
    fn test_build_i32_chunk_copies_only_requested_range() {
        let data = vec![vec![1, 2, 3, 4], vec![10, 20, 30, 40]];
        let chunk = build_i32_chunk(&data, 1..3);

        assert_eq!(chunk, vec![vec![2, 3], vec![20, 30]]);
    }

    #[test]
    fn test_collect_partial_failure_returns_total_without_errors() {
        let result = collect_partial_failure(12, Vec::new());
        assert_eq!(result.unwrap(), 12);
    }

    #[test]
    fn test_collect_partial_failure_preserves_failed_chunk_details() {
        let result = collect_partial_failure(
            7,
            vec![
                (1, "constraint violation".to_string()),
                (3, "connection lost".to_string()),
            ],
        );

        match result.unwrap_err() {
            OdbcError::BulkPartialFailure {
                rows_inserted_before_failure,
                failed_chunks,
                detail,
            } => {
                assert_eq!(rows_inserted_before_failure, 7);
                assert_eq!(failed_chunks, 2);
                assert!(detail.contains("chunk[1]: constraint violation"));
                assert!(detail.contains("chunk[3]: connection lost"));
            }
            other => panic!("Expected BulkPartialFailure, got {other:?}"),
        }
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

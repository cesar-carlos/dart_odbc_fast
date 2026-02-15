use crate::engine::core::QueryPipeline;
use crate::error::Result;
use crate::observability::Metrics;
use crate::protocol::ParamValue;
use odbc_api::Connection;
use std::sync::Arc;

lazy_static::lazy_static! {
    static ref PIPELINE: Arc<QueryPipeline> = Arc::new(QueryPipeline::new(100));
}

pub fn get_global_metrics() -> Arc<Metrics> {
    PIPELINE.get_metrics()
}

pub fn execute_query_with_connection(conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
    PIPELINE.execute_direct(conn, sql)
}

pub fn execute_query_with_params(
    conn: &Connection<'static>,
    sql: &str,
    params: &[ParamValue],
) -> Result<Vec<u8>> {
    PIPELINE.execute_with_params(conn, sql, params)
}

pub fn execute_query_with_params_and_timeout(
    conn: &Connection<'static>,
    sql: &str,
    params: &[ParamValue],
    timeout_sec: Option<usize>,
    fetch_size: Option<u32>,
) -> Result<Vec<u8>> {
    PIPELINE.execute_with_params_and_timeout(conn, sql, params, timeout_sec, fetch_size)
}

pub fn execute_multi_result(conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
    PIPELINE.execute_multi(conn, sql)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_global_metrics_returns_arc_metrics() {
        let metrics = get_global_metrics();
        assert!(std::sync::Arc::strong_count(&metrics) >= 1);
    }
}

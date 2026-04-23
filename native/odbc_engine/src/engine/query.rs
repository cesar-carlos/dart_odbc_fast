use crate::engine::core::QueryPipeline;
use crate::error::Result;
use crate::handles::CachedConnection;
use crate::observability::Metrics;
use crate::protocol::bound_param::{ParamDirection, ParamList};
use crate::protocol::{deserialize_param_buffer, ParamValue};
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

/// Execute SQL using cached connection (enables prepared-statement reuse when feature on).
pub fn execute_query_with_cached_connection(
    cached: &mut CachedConnection,
    sql: &str,
) -> Result<Vec<u8>> {
    PIPELINE.execute_direct_cached(cached, sql)
}

pub fn execute_query_with_params(
    conn: &Connection<'static>,
    sql: &str,
    params: &[ParamValue],
) -> Result<Vec<u8>> {
    PIPELINE.execute_with_params(conn, sql, params)
}

/// Like [execute_query_with_params] but accepts a raw FFI buffer: legacy
/// [ParamValue]… concatenation, or a DRT1 directed list (see [crate::protocol::bound_param]).
pub fn execute_query_with_param_buffer(
    conn: &Connection<'static>,
    sql: &str,
    param_bytes: &[u8],
) -> Result<Vec<u8>> {
    dispatch_param_buffer(conn, sql, param_bytes, None, None)
}

fn dispatch_param_buffer(
    conn: &Connection<'static>,
    sql: &str,
    param_bytes: &[u8],
    timeout_sec: Option<usize>,
    fetch_size: Option<u32>,
) -> Result<Vec<u8>> {
    let list = deserialize_param_buffer(param_bytes)?;
    match list {
        ParamList::Legacy(p) => {
            PIPELINE.execute_with_params_and_timeout(conn, sql, &p, timeout_sec, fetch_size)
        }
        ParamList::Directed(b) => {
            if b.iter()
                .all(|x| x.direction == ParamDirection::Input)
            {
                let p: Vec<ParamValue> = b.iter().map(|x| x.value.clone()).collect();
                PIPELINE
                    .execute_with_params_and_timeout(conn, sql, &p, timeout_sec, fetch_size)
            } else {
                PIPELINE
                    .execute_with_bound_params_and_timeout(conn, sql, &b, timeout_sec, fetch_size)
            }
        }
    }
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

/// [execute_query_with_params_and_timeout] with a raw buffer (legacy or DRT1).
pub fn execute_query_with_param_buffer_and_timeout(
    conn: &Connection<'static>,
    sql: &str,
    param_bytes: &[u8],
    timeout_sec: Option<usize>,
    fetch_size: Option<u32>,
) -> Result<Vec<u8>> {
    dispatch_param_buffer(conn, sql, param_bytes, timeout_sec, fetch_size)
}

pub fn execute_multi_result(conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
    PIPELINE.execute_multi(conn, sql)
}

pub fn execute_multi_result_with_params(
    conn: &Connection<'static>,
    sql: &str,
    params: &[ParamValue],
) -> Result<Vec<u8>> {
    PIPELINE.execute_multi_with_params(conn, sql, params)
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

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
    static ref COLUMNAR_PIPELINE: Arc<QueryPipeline> =
        Arc::new(QueryPipeline::with_columnar(100, false));
    static ref COLUMNAR_COMPRESSED_PIPELINE: Arc<QueryPipeline> =
        Arc::new(QueryPipeline::with_columnar(100, true));
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ResultEncoding {
    RowMajor,
    Columnar,
    ColumnarCompressed,
}

impl ResultEncoding {
    pub fn from_wire(code: u32) -> Option<Self> {
        match code {
            0 => Some(Self::RowMajor),
            1 => Some(Self::Columnar),
            2 => Some(Self::ColumnarCompressed),
            _ => None,
        }
    }

    fn pipeline(self) -> Arc<QueryPipeline> {
        match self {
            Self::RowMajor => Arc::clone(&PIPELINE),
            Self::Columnar => Arc::clone(&COLUMNAR_PIPELINE),
            Self::ColumnarCompressed => Arc::clone(&COLUMNAR_COMPRESSED_PIPELINE),
        }
    }
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
    dispatch_param_buffer(conn, sql, param_bytes, None, None, ResultEncoding::RowMajor)
}

pub fn execute_query_with_param_buffer_encoding(
    conn: &Connection<'static>,
    sql: &str,
    param_bytes: &[u8],
    encoding: ResultEncoding,
) -> Result<Vec<u8>> {
    dispatch_param_buffer(conn, sql, param_bytes, None, None, encoding)
}

fn dispatch_param_buffer(
    conn: &Connection<'static>,
    sql: &str,
    param_bytes: &[u8],
    timeout_sec: Option<usize>,
    fetch_size: Option<u32>,
    encoding: ResultEncoding,
) -> Result<Vec<u8>> {
    let list = deserialize_param_buffer(param_bytes)?;
    let pipeline = encoding.pipeline();
    match list {
        ParamList::Legacy(p) => {
            pipeline.execute_with_params_and_timeout(conn, sql, &p, timeout_sec, fetch_size)
        }
        ParamList::Directed(b) => {
            if b.iter().all(|x| x.direction == ParamDirection::Input) {
                let p: Vec<ParamValue> = b.iter().map(|x| x.value.clone()).collect();
                pipeline.execute_with_params_and_timeout(conn, sql, &p, timeout_sec, fetch_size)
            } else {
                pipeline.execute_with_bound_params_and_timeout(
                    conn,
                    sql,
                    &b,
                    timeout_sec,
                    fetch_size,
                )
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
    dispatch_param_buffer(
        conn,
        sql,
        param_bytes,
        timeout_sec,
        fetch_size,
        ResultEncoding::RowMajor,
    )
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
    fn result_encoding_from_wire_maps_stable_codes() {
        assert_eq!(ResultEncoding::from_wire(0), Some(ResultEncoding::RowMajor));
        assert_eq!(ResultEncoding::from_wire(1), Some(ResultEncoding::Columnar));
        assert_eq!(
            ResultEncoding::from_wire(2),
            Some(ResultEncoding::ColumnarCompressed)
        );
    }

    #[test]
    fn result_encoding_from_wire_rejects_unknown() {
        assert_eq!(ResultEncoding::from_wire(3), None);
        assert_eq!(ResultEncoding::from_wire(u32::MAX), None);
    }

    #[test]
    fn test_get_global_metrics_returns_arc_metrics() {
        let metrics = get_global_metrics();
        assert!(std::sync::Arc::strong_count(&metrics) >= 1);
    }

    #[test]
    fn result_encoding_equality_and_debug() {
        assert_eq!(ResultEncoding::RowMajor, ResultEncoding::RowMajor);
        assert_ne!(ResultEncoding::RowMajor, ResultEncoding::Columnar);
        assert!(format!("{:?}", ResultEncoding::ColumnarCompressed).contains("ColumnarCompressed"));
    }

    #[test]
    fn deserialize_empty_param_buffer_is_legacy_empty_list() {
        use crate::protocol::bound_param::ParamList;

        let list = deserialize_param_buffer(&[]).expect("empty buffer");
        match list {
            ParamList::Legacy(p) => assert!(p.is_empty()),
            ParamList::Directed(_) => panic!("empty buffer must be legacy list"),
        }
    }

    #[test]
    fn deserialize_legacy_param_buffer_rejects_truncated_payload() {
        // Legacy format: one byte type tag without following value bytes.
        let garbage = [0xFFu8];
        let err = deserialize_param_buffer(&garbage).unwrap_err();
        assert!(matches!(err, crate::error::OdbcError::ValidationError(_)));
    }

    #[test]
    fn deserialize_drt1_rejects_truncated_value_after_direction() {
        let mut buf = Vec::from(*b"DRT1");
        buf.extend_from_slice(&1u32.to_le_bytes());
        buf.push(0); // ParamDirection::Input — valid direction, missing ParamValue bytes.
        let err = deserialize_param_buffer(&buf).unwrap_err();
        match err {
            crate::error::OdbcError::ValidationError(msg) => {
                assert!(
                    msg.contains("truncated"),
                    "expected truncated value error, got {msg}"
                );
            }
            other => panic!("expected ValidationError, got {other:?}"),
        }
    }

    #[test]
    fn deserialize_drt1_rejects_invalid_direction_code() {
        let mut buf = Vec::from(*b"DRT1");
        buf.extend_from_slice(&1u32.to_le_bytes());
        buf.push(99); // not a valid ParamDirection
        let err = deserialize_param_buffer(&buf).unwrap_err();
        match err {
            crate::error::OdbcError::ValidationError(msg) => {
                assert!(msg.contains("invalid direction"));
            }
            other => panic!("expected ValidationError, got {other:?}"),
        }
    }

    #[test]
    fn result_encoding_pipeline_row_major_uses_global_singleton() {
        let a = ResultEncoding::RowMajor.pipeline();
        let b = ResultEncoding::RowMajor.pipeline();
        assert!(std::sync::Arc::ptr_eq(&a, &b));
    }

    #[test]
    fn result_encoding_pipeline_columnar_uses_singletons() {
        let row = ResultEncoding::RowMajor.pipeline();
        let col = ResultEncoding::Columnar.pipeline();
        let col_again = ResultEncoding::Columnar.pipeline();
        let compressed = ResultEncoding::ColumnarCompressed.pipeline();
        let compressed_again = ResultEncoding::ColumnarCompressed.pipeline();
        assert!(!std::sync::Arc::ptr_eq(&row, &col));
        assert!(!std::sync::Arc::ptr_eq(&col, &compressed));
        assert!(std::sync::Arc::ptr_eq(&col, &col_again));
        assert!(std::sync::Arc::ptr_eq(&compressed, &compressed_again));
    }

    #[test]
    fn should_deserialize_legacy_integer_param_buffer() {
        use crate::protocol::bound_param::ParamList;

        let mut buf = ParamValue::Integer(42).serialize();
        buf.extend(ParamValue::Integer(7).serialize());
        let list = deserialize_param_buffer(&buf).expect("legacy integers");
        match list {
            ParamList::Legacy(p) => {
                assert_eq!(p.len(), 2);
                assert_eq!(p[0], ParamValue::Integer(42));
                assert_eq!(p[1], ParamValue::Integer(7));
            }
            ParamList::Directed(_) => panic!("expected legacy list"),
        }
    }

    #[test]
    fn should_deserialize_drt1_input_and_output_params() {
        use crate::protocol::bound_param::{BoundParam, ParamDirection, ParamList};

        let in_bytes = ParamValue::Integer(1).serialize();
        let out_bytes = ParamValue::Null.serialize();
        let mut buf: Vec<u8> = b"DRT1".to_vec();
        buf.extend_from_slice(&2u32.to_le_bytes());
        buf.push(ParamDirection::Input as u8);
        buf.extend_from_slice(&in_bytes);
        buf.push(ParamDirection::Output as u8);
        buf.extend_from_slice(&out_bytes);

        let list = deserialize_param_buffer(&buf).expect("drt1 in+out");
        match list {
            ParamList::Directed(b) => {
                assert_eq!(
                    b,
                    vec![
                        BoundParam {
                            direction: ParamDirection::Input,
                            value: ParamValue::Integer(1),
                        },
                        BoundParam {
                            direction: ParamDirection::Output,
                            value: ParamValue::Null,
                        },
                    ]
                );
            }
            ParamList::Legacy(_) => panic!("expected directed list"),
        }
    }

    #[test]
    fn should_reject_drt1_when_count_exceeds_max_param_limit() {
        let mut buf: Vec<u8> = b"DRT1".to_vec();
        buf.extend_from_slice(&u32::MAX.to_le_bytes());
        assert!(deserialize_param_buffer(&buf).is_err());
    }
}

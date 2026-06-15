//! Stream FFI adapter logic — keeps `mod.rs` validate→delegate→return.

use super::super::global::*;
use super::helpers::{parse_stream_sql, resolve_chunk_size, resolve_fetch_size};
use crate::engine::streaming::StreamingExecutor;
use crate::engine::{ResultEncoding, StreamState};
use crate::error::OdbcError;
use crate::ffi::state;
use std::os::raw::c_char;
use std::sync::Arc;

/// Validates a wire `result_encoding` code; records a connection error on failure.
pub(crate) fn parse_result_encoding(conn_id: u32, result_encoding: u32) -> Option<ResultEncoding> {
    match ResultEncoding::from_wire(result_encoding) {
        Some(encoding) => Some(encoding),
        None => {
            let mut gs = try_lock_global_state()?;
            set_connection_error(
                &mut gs,
                conn_id,
                format!("Invalid result_encoding: {result_encoding}"),
            );
            None
        }
    }
}

/// Buffer-mode streaming (`odbc_stream_start`).
pub(crate) fn stream_start(conn_id: u32, sql: *const c_char, chunk_size: u32) -> u32 {
    let Some(sql_str) = parse_stream_sql(sql) else {
        return 0;
    };

    let chunk_size = resolve_chunk_size(chunk_size);
    let spill_threshold_mb = std::env::var("ODBC_STREAM_SPILL_THRESHOLD_MB")
        .ok()
        .and_then(|s| s.parse::<usize>().ok())
        .filter(|&t| t > 0);

    let Some(mut state) = try_lock_global_state() else {
        return 0;
    };
    let mut target = match take_runnable_connection(&mut state, conn_id) {
        Ok(target) => target,
        Err(e) => {
            set_connection_structured_error(&mut state, conn_id, e.to_structured());
            return 0;
        }
    };
    drop(state);

    let executor = StreamingExecutor::new(chunk_size);
    let stream_state = match &mut target {
        RunnableConnection::Regular(conn_arc) => {
            let conn_guard = match conn_arc.lock() {
                Ok(g) => g,
                Err(_) => {
                    let Some(mut state) = try_lock_global_state() else {
                        return 0;
                    };
                    set_connection_error(
                        &mut state,
                        conn_id,
                        "Failed to lock connection".to_string(),
                    );
                    return 0;
                }
            };
            if let Some(threshold) = spill_threshold_mb {
                executor.execute_streaming_with_spill(
                    conn_guard.connection(),
                    sql_str,
                    Some(threshold),
                )
            } else {
                executor
                    .execute_streaming(conn_guard.connection(), sql_str)
                    .map(StreamState::InMemory)
            }
        }
        RunnableConnection::Pooled { pooled, .. } => match pooled.lock() {
            Ok(conn_guard) => {
                if let Some(threshold) = spill_threshold_mb {
                    executor.execute_streaming_with_spill(
                        conn_guard.get_connection(),
                        sql_str,
                        Some(threshold),
                    )
                } else {
                    executor
                        .execute_streaming(conn_guard.get_connection(), sql_str)
                        .map(StreamState::InMemory)
                }
            }
            Err(_) => Err(OdbcError::InternalError(
                "Failed to lock pooled connection".to_string(),
            )),
        },
    };

    let Some(mut state) = try_lock_global_state() else {
        return 0;
    };
    restore_pooled_connection(&mut state, conn_id, target);

    match stream_state {
        Ok(stream_state) => {
            let stream_id = state::allocate_stream_id(conn_id);
            if stream_id == 0 {
                return 0;
            }
            state::insert_stream(stream_id, conn_id, StreamKind::Buffer(stream_state));
            stream_id
        }
        Err(e) => {
            set_connection_error(
                &mut state,
                conn_id,
                format!("odbc_stream_start failed: {}", e),
            );
            0
        }
    }
}

fn start_batched_stream_common(
    conn_id: u32,
    sql: *const c_char,
    fetch_size: u32,
    chunk_size: u32,
    encoding: ResultEncoding,
    error_prefix: &str,
) -> u32 {
    let Some(sql_str) = parse_stream_sql(sql) else {
        return 0;
    };

    let Some(mut state) = try_lock_global_state() else {
        return 0;
    };

    let reservation = match reserve_stream_start(&mut state, conn_id) {
        Ok(reservation) => reservation,
        Err(e) => {
            set_connection_structured_error(&mut state, conn_id, e.to_structured());
            return 0;
        }
    };

    let fetch_size = resolve_fetch_size(fetch_size);
    let chunk_size = resolve_chunk_size(chunk_size);
    let sql_owned = sql_str.to_string();

    drop(state);

    let executor = StreamingExecutor::new(chunk_size);
    let start_result = match &reservation.target {
        StreamStartTarget::Regular { handles } => executor.start_batched_stream(
            handles.clone(),
            conn_id,
            sql_owned,
            fetch_size,
            chunk_size,
            encoding,
        ),
        StreamStartTarget::Pooled { pool_id, pooled } => executor.start_batched_stream_pooled(
            Arc::clone(pooled),
            sql_owned,
            fetch_size,
            chunk_size,
            Some(pooled_stream_completion(conn_id, *pool_id)),
            encoding,
        ),
    };

    match start_result {
        Ok(batched_state) => {
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            insert_stream(
                &mut state,
                reservation.stream_id,
                conn_id,
                StreamKind::Batched(batched_state),
            )
        }
        Err(e) => {
            release_pooled_stream_reservation(conn_id, &reservation.target);
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            set_connection_error(
                &mut state,
                conn_id,
                format!("{} failed: {}", error_prefix, e),
            );
            0
        }
    }
}

/// Batched streaming with row-major encoding.
pub(crate) fn stream_start_batched(
    conn_id: u32,
    sql: *const c_char,
    fetch_size: u32,
    chunk_size: u32,
) -> u32 {
    start_batched_stream_common(
        conn_id,
        sql,
        fetch_size,
        chunk_size,
        ResultEncoding::RowMajor,
        "odbc_stream_start_batched",
    )
}

/// Batched streaming with explicit wire encoding.
pub(crate) fn stream_start_batched_options(
    conn_id: u32,
    sql: *const c_char,
    fetch_size: u32,
    chunk_size: u32,
    result_encoding: u32,
) -> u32 {
    let Some(encoding) = parse_result_encoding(conn_id, result_encoding) else {
        return 0;
    };

    start_batched_stream_common(
        conn_id,
        sql,
        fetch_size,
        chunk_size,
        encoding,
        "odbc_stream_start_batched_options",
    )
}

fn start_async_stream_common(
    conn_id: u32,
    sql: *const c_char,
    fetch_size: u32,
    chunk_size: u32,
    encoding: ResultEncoding,
    error_prefix: &str,
) -> u32 {
    let Some(sql_str) = parse_stream_sql(sql) else {
        return 0;
    };

    let Some(mut state) = try_lock_global_state() else {
        return 0;
    };

    let reservation = match reserve_stream_start(&mut state, conn_id) {
        Ok(reservation) => reservation,
        Err(e) => {
            set_connection_structured_error(&mut state, conn_id, e.to_structured());
            return 0;
        }
    };

    let fetch_size = resolve_fetch_size(fetch_size);
    let chunk_size = resolve_chunk_size(chunk_size);
    let sql_owned = sql_str.to_string();

    drop(state);

    let executor = StreamingExecutor::new(chunk_size);
    let start_result = match &reservation.target {
        StreamStartTarget::Regular { handles } => executor.start_async_stream(
            handles.clone(),
            conn_id,
            sql_owned,
            fetch_size,
            chunk_size,
            encoding,
        ),
        StreamStartTarget::Pooled { pool_id, pooled } => executor.start_async_stream_pooled(
            Arc::clone(pooled),
            sql_owned,
            fetch_size,
            chunk_size,
            Some(pooled_stream_completion(conn_id, *pool_id)),
            encoding,
        ),
    };

    match start_result {
        Ok(async_state) => {
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            insert_stream(
                &mut state,
                reservation.stream_id,
                conn_id,
                StreamKind::AsyncBatched(async_state),
            )
        }
        Err(e) => {
            release_pooled_stream_reservation(conn_id, &reservation.target);
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            set_connection_error(
                &mut state,
                conn_id,
                format!("{} failed: {}", error_prefix, e),
            );
            0
        }
    }
}

/// Async batched streaming with row-major encoding.
pub(crate) fn stream_start_async(
    conn_id: u32,
    sql: *const c_char,
    fetch_size: u32,
    chunk_size: u32,
) -> u32 {
    start_async_stream_common(
        conn_id,
        sql,
        fetch_size,
        chunk_size,
        ResultEncoding::RowMajor,
        "odbc_stream_start_async",
    )
}

/// Async batched streaming with explicit wire encoding.
pub(crate) fn stream_start_async_options(
    conn_id: u32,
    sql: *const c_char,
    fetch_size: u32,
    chunk_size: u32,
    result_encoding: u32,
) -> u32 {
    let Some(encoding) = parse_result_encoding(conn_id, result_encoding) else {
        return 0;
    };

    start_async_stream_common(
        conn_id,
        sql,
        fetch_size,
        chunk_size,
        encoding,
        "odbc_stream_start_async_options",
    )
}

fn start_multi_batched_common(
    conn_id: u32,
    sql: *const c_char,
    fetch_size: u32,
    chunk_size: u32,
    async_mode: bool,
    result_encoding: ResultEncoding,
    error_prefix: &str,
) -> u32 {
    let Some(sql_str) = parse_stream_sql(sql) else {
        return 0;
    };
    let Some(mut state) = try_lock_global_state() else {
        return 0;
    };
    let reservation = match reserve_stream_start(&mut state, conn_id) {
        Ok(reservation) => reservation,
        Err(e) => {
            set_connection_structured_error(&mut state, conn_id, e.to_structured());
            return 0;
        }
    };
    let fetch_size = resolve_fetch_size(fetch_size);
    let chunk_size = resolve_chunk_size(chunk_size);
    let sql_owned = sql_str.to_string();
    drop(state);

    let start_result = if async_mode {
        match &reservation.target {
            StreamStartTarget::Regular { handles } => crate::engine::start_multi_async_stream(
                handles.clone(),
                conn_id,
                sql_owned,
                chunk_size,
                fetch_size,
                result_encoding,
            )
            .map(StreamKind::AsyncBatched),
            StreamStartTarget::Pooled { pool_id, pooled } => {
                crate::engine::start_multi_async_stream_pooled(
                    Arc::clone(pooled),
                    sql_owned,
                    chunk_size,
                    fetch_size,
                    result_encoding,
                    Some(pooled_stream_completion(conn_id, *pool_id)),
                )
                .map(StreamKind::AsyncBatched)
            }
        }
    } else {
        match &reservation.target {
            StreamStartTarget::Regular { handles } => crate::engine::start_multi_batched_stream(
                handles.clone(),
                conn_id,
                sql_owned,
                chunk_size,
                fetch_size,
                result_encoding,
            )
            .map(StreamKind::Batched),
            StreamStartTarget::Pooled { pool_id, pooled } => {
                crate::engine::start_multi_batched_stream_pooled(
                    Arc::clone(pooled),
                    sql_owned,
                    chunk_size,
                    fetch_size,
                    result_encoding,
                    Some(pooled_stream_completion(conn_id, *pool_id)),
                )
                .map(StreamKind::Batched)
            }
        }
    };

    match start_result {
        Ok(kind) => {
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            insert_stream(&mut state, reservation.stream_id, conn_id, kind)
        }
        Err(e) => {
            release_pooled_stream_reservation(conn_id, &reservation.target);
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            set_connection_error(
                &mut state,
                conn_id,
                format!("{} failed: {}", error_prefix, e),
            );
            0
        }
    }
}

/// Multi-result batched streaming.
pub(crate) fn stream_multi_start_batched(conn_id: u32, sql: *const c_char, chunk_size: u32) -> u32 {
    start_multi_batched_common(
        conn_id,
        sql,
        0,
        chunk_size,
        false,
        ResultEncoding::RowMajor,
        "odbc_stream_multi_start_batched",
    )
}

/// Multi-result batched streaming with explicit wire encoding.
pub(crate) fn stream_multi_start_batched_options(
    conn_id: u32,
    sql: *const c_char,
    fetch_size: u32,
    chunk_size: u32,
    result_encoding: u32,
) -> u32 {
    let Some(encoding) = parse_result_encoding(conn_id, result_encoding) else {
        return 0;
    };

    start_multi_batched_common(
        conn_id,
        sql,
        fetch_size,
        chunk_size,
        false,
        encoding,
        "odbc_stream_multi_start_batched_options",
    )
}

/// Multi-result async batched streaming.
pub(crate) fn stream_multi_start_async(conn_id: u32, sql: *const c_char, chunk_size: u32) -> u32 {
    start_multi_batched_common(
        conn_id,
        sql,
        0,
        chunk_size,
        true,
        ResultEncoding::RowMajor,
        "odbc_stream_multi_start_async",
    )
}

/// Multi-result async batched streaming with explicit wire encoding.
pub(crate) fn stream_multi_start_async_options(
    conn_id: u32,
    sql: *const c_char,
    fetch_size: u32,
    chunk_size: u32,
    result_encoding: u32,
) -> u32 {
    let Some(encoding) = parse_result_encoding(conn_id, result_encoding) else {
        return 0;
    };

    start_multi_batched_common(
        conn_id,
        sql,
        fetch_size,
        chunk_size,
        true,
        encoding,
        "odbc_stream_multi_start_async_options",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::ResultEncoding;
    use crate::ffi::global_state::{DEFAULT_CHUNK_SIZE, DEFAULT_FETCH_SIZE};

    #[test]
    fn parse_result_encoding_accepts_wire_codes() {
        assert_eq!(ResultEncoding::from_wire(0), Some(ResultEncoding::RowMajor));
        assert_eq!(ResultEncoding::from_wire(1), Some(ResultEncoding::Columnar));
        assert_eq!(
            ResultEncoding::from_wire(2),
            Some(ResultEncoding::ColumnarCompressed)
        );
        assert!(ResultEncoding::from_wire(99).is_none());
    }

    #[test]
    fn parse_stream_sql_rejects_null_pointer() {
        assert!(parse_stream_sql(std::ptr::null()).is_none());
    }

    #[test]
    fn resolve_fetch_size_uses_default_when_zero() {
        assert_eq!(resolve_fetch_size(0), DEFAULT_FETCH_SIZE as usize);
    }

    #[test]
    fn resolve_chunk_size_uses_default_when_zero() {
        assert_eq!(resolve_chunk_size(0), DEFAULT_CHUNK_SIZE as usize);
    }
}

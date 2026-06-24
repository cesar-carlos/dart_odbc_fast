use crate::engine::query::ResultEncoding;
use crate::engine::SharedHandleManager;
pub(crate) use crate::error::{OdbcError, Result};
use crate::handles::SharedConnection;
pub(crate) use crate::pool::SharedPooledConnection;
use std::os::raw::c_uint;
pub(crate) use std::time::Instant;

use super::global::try_cached_params_with_encoding;

use super::global_state::{
    set_connection_error, set_connection_structured_error, set_out_written_zero,
    try_lock_global_state, write_connection_output_buffer, GlobalState, StreamKind, FFI_OK,
};
use super::state;

pub(crate) enum RunnableConnection {
    Regular(SharedConnection),
    Pooled {
        pool_id: u32,
        pooled: SharedPooledConnection,
    },
}

impl RunnableConnection {
    pub(crate) fn with_connection<F, T>(&self, f: F) -> Result<T>
    where
        F: FnOnce(&odbc_api::Connection<'static>) -> Result<T>,
    {
        match self {
            Self::Regular(conn_arc) => {
                let conn = conn_arc.lock().map_err(|_| {
                    OdbcError::InternalError("Failed to lock connection".to_string())
                })?;
                f(conn.connection())
            }
            Self::Pooled { pooled, .. } => {
                let conn = pooled.lock().map_err(|_| {
                    OdbcError::InternalError("Failed to lock pooled connection".to_string())
                })?;
                f(conn.get_connection())
            }
        }
    }
}

pub(crate) fn take_runnable_connection(
    state: &mut GlobalState,
    conn_id: u32,
) -> Result<RunnableConnection> {
    if let Some(handles) = state::connection_handles(conn_id) {
        let conn_arc = {
            let handles_guard = handles.lock().map_err(|_| {
                OdbcError::InternalError("Failed to lock handles mutex".to_string())
            })?;
            handles_guard.get_connection(conn_id)?
        };
        return Ok(RunnableConnection::Regular(conn_arc));
    }

    if let Some(entry) = state.pooled_connections.get(&conn_id).cloned() {
        *state.pooled_busy_counts.entry(entry.pool_id).or_insert(0) += 1;
        *state
            .pooled_connection_busy_counts
            .entry(conn_id)
            .or_insert(0) += 1;
        return Ok(RunnableConnection::Pooled {
            pool_id: entry.pool_id,
            pooled: entry.pooled,
        });
    }

    Err(OdbcError::InvalidHandle(conn_id))
}

pub(crate) fn restore_pooled_connection(
    state: &mut GlobalState,
    conn_id: u32,
    target: RunnableConnection,
) {
    if let RunnableConnection::Pooled { pool_id, .. } = target {
        decrement_pooled_busy_counts(state, pool_id, conn_id);
    }
}

pub(crate) fn decrement_pooled_busy_counts(state: &mut GlobalState, pool_id: u32, conn_id: u32) {
    if let Some(count) = state.pooled_busy_counts.get_mut(&pool_id) {
        *count = count.saturating_sub(1);
        if *count == 0 {
            state.pooled_busy_counts.remove(&pool_id);
        }
    }
    if let Some(count) = state.pooled_connection_busy_counts.get_mut(&conn_id) {
        *count = count.saturating_sub(1);
        if *count == 0 {
            state.pooled_connection_busy_counts.remove(&conn_id);
        }
    }
}

pub(crate) enum StreamStartTarget {
    Regular {
        handles: SharedHandleManager,
    },
    Pooled {
        pool_id: u32,
        pooled: SharedPooledConnection,
    },
}

pub(crate) struct StreamReservation {
    pub(crate) stream_id: u32,
    pub(crate) target: StreamStartTarget,
}

pub(crate) fn allocate_stream_id(state: &mut GlobalState, conn_id: u32) -> u32 {
    let _ = state;
    state::allocate_stream_id(conn_id)
}

pub(crate) fn reserve_stream_start(
    state: &mut GlobalState,
    conn_id: u32,
) -> Result<StreamReservation> {
    let target = if let Some(handles) = state::connection_handles(conn_id) {
        StreamStartTarget::Regular { handles }
    } else if let Some(entry) = state.pooled_connections.get(&conn_id).cloned() {
        *state.pooled_busy_counts.entry(entry.pool_id).or_insert(0) += 1;
        *state
            .pooled_connection_busy_counts
            .entry(conn_id)
            .or_insert(0) += 1;
        StreamStartTarget::Pooled {
            pool_id: entry.pool_id,
            pooled: entry.pooled,
        }
    } else {
        return Err(OdbcError::InvalidHandle(conn_id));
    };

    let stream_id = allocate_stream_id(state, conn_id);
    if stream_id == 0 {
        if let StreamStartTarget::Pooled { pool_id, .. } = &target {
            decrement_pooled_busy_counts(state, *pool_id, conn_id);
        }
        return Err(OdbcError::InternalError(
            "Failed to allocate stream ID".to_string(),
        ));
    }

    Ok(StreamReservation { stream_id, target })
}

pub(crate) fn pooled_stream_completion(
    conn_id: u32,
    pool_id: u32,
) -> Box<dyn FnOnce() + Send + 'static> {
    Box::new(move || {
        if let Some(mut state) = try_lock_global_state() {
            decrement_pooled_busy_counts(&mut state, pool_id, conn_id);
        }
    })
}

pub(crate) fn release_pooled_stream_reservation(conn_id: u32, target: &StreamStartTarget) {
    if let StreamStartTarget::Pooled { pool_id, .. } = target {
        if let Some(mut state) = try_lock_global_state() {
            decrement_pooled_busy_counts(&mut state, *pool_id, conn_id);
        }
    }
}

pub(crate) fn insert_stream(
    _state: &mut GlobalState,
    stream_id: u32,
    conn_id: u32,
    stream: StreamKind,
) -> u32 {
    state::insert_stream(stream_id, conn_id, stream);
    stream_id
}

pub(crate) fn run_buffered_connection_call<F>(
    conn_id: u32,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
    run: F,
) -> i32
where
    F: FnOnce(&odbc_api::Connection<'static>) -> Result<Vec<u8>>,
{
    let Some(mut state) = try_lock_global_state() else {
        set_out_written_zero(out_written);
        return -1;
    };
    let metrics = state::ffi_metrics();
    let start = Instant::now();
    let mut target = match take_runnable_connection(&mut state, conn_id) {
        Ok(target) => target,
        Err(e) => {
            set_connection_structured_error(&mut state, conn_id, e.to_structured());
            set_out_written_zero(out_written);
            return -1;
        }
    };
    drop(state);

    let result = if let RunnableConnection::Regular(conn_arc) = &mut target {
        let conn_guard = match conn_arc.lock() {
            Ok(g) => g,
            Err(_) => {
                let Some(mut state) = try_lock_global_state() else {
                    set_out_written_zero(out_written);
                    return -1;
                };
                set_connection_error(&mut state, conn_id, "Failed to lock connection".to_string());
                set_out_written_zero(out_written);
                return -1;
            }
        };
        run(conn_guard.connection())
    } else {
        target.with_connection(run)
    };

    let Some(mut state) = try_lock_global_state() else {
        set_out_written_zero(out_written);
        return -1;
    };
    restore_pooled_connection(&mut state, conn_id, target);

    match result {
        Ok(data) => {
            let status = write_connection_output_buffer(
                &mut state,
                conn_id,
                &data,
                out_buffer,
                buffer_len,
                out_written,
            );
            if status == FFI_OK {
                metrics.record_query(start.elapsed());
            } else {
                metrics.record_error();
            }
            status
        }
        Err(e) => {
            metrics.record_error();
            set_connection_structured_error(&mut state, conn_id, e.to_structured());
            set_out_written_zero(out_written);
            -1
        }
    }
}

pub(crate) fn run_async_query(
    conn_id: u32,
    sql: &str,
    params: Option<&[u8]>,
    result_encoding: u32,
) -> Result<Vec<u8>> {
    let Some(mut state) = try_lock_global_state() else {
        return Err(OdbcError::InternalError(
            "Failed to lock global state".to_string(),
        ));
    };

    let encoding = ResultEncoding::from_wire(result_encoding).unwrap_or(ResultEncoding::RowMajor);

    state::ffi_audit_logger().log_query(conn_id, sql);
    let metrics = state::ffi_metrics();
    let start = Instant::now();
    let mut target = take_runnable_connection(&mut state, conn_id)?;
    drop(state);

    let params_slice = params.unwrap_or(&[]);
    let result = match &mut target {
        RunnableConnection::Regular(conn_arc) => match conn_arc.lock() {
            Ok(mut conn_guard) => {
                if params_slice.is_empty() {
                    conn_guard.execute_with_encoding(sql, encoding)
                } else {
                    try_cached_params_with_encoding(&mut conn_guard, sql, params_slice, encoding)
                }
            }
            Err(_) => Err(OdbcError::InternalError(
                "Failed to lock connection".to_string(),
            )),
        },
        RunnableConnection::Pooled { pooled, .. } => {
            let mut conn_guard = pooled.lock().map_err(|_| {
                OdbcError::InternalError("Failed to lock pooled connection".to_string())
            })?;
            if params_slice.is_empty() {
                conn_guard.cached_mut().execute_with_encoding(sql, encoding)
            } else {
                try_cached_params_with_encoding(
                    conn_guard.cached_mut(),
                    sql,
                    params_slice,
                    encoding,
                )
            }
        }
    };

    let Some(mut state) = try_lock_global_state() else {
        return Err(OdbcError::InternalError(
            "Failed to lock global state".to_string(),
        ));
    };
    restore_pooled_connection(&mut state, conn_id, target);

    if result.is_ok() {
        metrics.record_query(start.elapsed());
    } else {
        metrics.record_error();
    }
    result
}

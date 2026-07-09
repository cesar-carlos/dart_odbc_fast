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

/// Resolve a runnable connection. Regular connections use the connections
/// shard; pooled connections bump busy counts on the pools shard. The
/// residual `GlobalState` parameter is unused for lookup and kept only so
/// call sites that already hold the outer mutex keep a stable signature.
pub(crate) fn take_runnable_connection(
    _state: &mut GlobalState,
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

    if let Some((pool_id, pooled)) = state::reserve_pooled_runnable(conn_id) {
        return Ok(RunnableConnection::Pooled { pool_id, pooled });
    }

    Err(OdbcError::InvalidHandle(conn_id))
}

pub(crate) fn restore_pooled_connection(
    _state: &mut GlobalState,
    conn_id: u32,
    target: RunnableConnection,
) {
    if let RunnableConnection::Pooled { pool_id, .. } = target {
        state::decrement_pooled_busy_counts(pool_id, conn_id);
    }
}

/// Restores pooled busy-count reservations from [`take_runnable_connection`]
/// when an ODBC call returns without an explicit [`restore_pooled_connection`].
pub(crate) struct RunnableTargetGuard {
    conn_id: u32,
    target: Option<RunnableConnection>,
}

impl RunnableTargetGuard {
    pub(crate) fn new(conn_id: u32, target: RunnableConnection) -> Self {
        Self {
            conn_id,
            target: Some(target),
        }
    }

    pub(crate) fn disarm(&mut self) {
        self.target = None;
    }

    pub(crate) fn target_mut(&mut self) -> &mut RunnableConnection {
        self.target
            .as_mut()
            .expect("RunnableTargetGuard disarmed before ODBC call")
    }

    pub(crate) fn take_target(&mut self) -> RunnableConnection {
        let target = self
            .target
            .take()
            .expect("RunnableTargetGuard target already taken");
        self.disarm();
        target
    }
}

impl Drop for RunnableTargetGuard {
    fn drop(&mut self) {
        if let Some(RunnableConnection::Pooled { pool_id, .. }) = self.target.take() {
            state::decrement_pooled_busy_counts(pool_id, self.conn_id);
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
    } else if let Some((pool_id, pooled)) = state::reserve_pooled_runnable(conn_id) {
        StreamStartTarget::Pooled { pool_id, pooled }
    } else {
        return Err(OdbcError::InvalidHandle(conn_id));
    };

    let stream_id = allocate_stream_id(state, conn_id);
    if stream_id == 0 {
        if let StreamStartTarget::Pooled { pool_id, .. } = &target {
            state::decrement_pooled_busy_counts(*pool_id, conn_id);
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
        state::decrement_pooled_busy_counts(pool_id, conn_id);
    })
}

pub(crate) fn release_pooled_stream_reservation(conn_id: u32, target: &StreamStartTarget) {
    if let StreamStartTarget::Pooled { pool_id, .. } = target {
        state::decrement_pooled_busy_counts(*pool_id, conn_id);
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
    let target = match take_runnable_connection(&mut state, conn_id) {
        Ok(target) => target,
        Err(e) => {
            set_connection_structured_error(&mut state, conn_id, e.to_structured());
            set_out_written_zero(out_written);
            return -1;
        }
    };
    let mut target_guard = RunnableTargetGuard::new(conn_id, target);
    drop(state);

    let result = if let RunnableConnection::Regular(conn_arc) = target_guard.target_mut() {
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
        target_guard.target_mut().with_connection(run)
    };

    let Some(mut state) = try_lock_global_state() else {
        set_out_written_zero(out_written);
        return -1;
    };
    restore_pooled_connection(&mut state, conn_id, target_guard.take_target());

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
    let target = take_runnable_connection(&mut state, conn_id)?;
    let mut target_guard = RunnableTargetGuard::new(conn_id, target);
    drop(state);

    let params_slice = params.unwrap_or(&[]);
    let result = match target_guard.target_mut() {
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
    restore_pooled_connection(&mut state, conn_id, target_guard.take_target());

    if result.is_ok() {
        metrics.record_query(start.elapsed());
    } else {
        metrics.record_error();
    }
    result
}

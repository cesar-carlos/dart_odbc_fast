// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use super::global::*;
use super::prelude::*;
use crate::ffi::state;

use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_uint};

/// Prepare a statement with optional timeout.
#[no_mangle]
pub extern "C" fn odbc_prepare(conn_id: c_uint, sql: *const c_char, timeout_ms: c_uint) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        if sql.is_null() {
            return 0;
        }

        // SAFETY: `sql` is non-null (checked above); caller guarantees a valid
        // NUL-terminated C string for the duration of this call.
        let c_str = unsafe { CStr::from_ptr(sql) };
        let sql_str = match c_str.to_str() {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        };

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };

        if !state::contains_connection(conn_id) && !state.pooled_connections.contains_key(&conn_id)
        {
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return 0;
        }

        let stmt = StatementHandle::new(conn_id, sql_str, timeout_ms);
        let stmt_id = {
            let mut id = 0u32;
            for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
                let candidate = state.next_stmt_id;
                state.next_stmt_id = state.next_stmt_id.wrapping_add(1);
                if candidate != 0 && !state.statements.contains_key(&candidate) {
                    id = candidate;
                    break;
                }
            }
            if id == 0 {
                set_connection_error(
                    &mut state,
                    conn_id,
                    "Failed to allocate statement ID".to_string(),
                );
                return 0;
            }
            id
        };
        state.statements.insert(stmt_id, stmt);
        stmt_id
    })
}

/// Execute a prepared statement.
/// stmt_id: from odbc_prepare
/// params_buffer: serialized ParamValue array, or NULL for no params
/// params_len: length of params_buffer
/// out_buffer, buffer_len, out_written: same contract as odbc_exec_query
/// Returns: 0 on success, -1 on error, -2 if buffer too small
#[no_mangle]
pub extern "C" fn odbc_execute(
    stmt_id: c_uint,
    params_buffer: *const u8,
    params_len: c_uint,
    timeout_override_ms: c_uint,
    fetch_size: c_uint,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if out_buffer.is_null() || out_written.is_null() {
            return -1;
        }

        let (conn_id, sql_str, stored_timeout_sec) = {
            let Some(state) = try_lock_global_state() else {
                return -1;
            };
            match state.statements.get(&stmt_id) {
                Some(s) => (s.conn_id(), s.sql().to_string(), s.timeout_sec()),
                None => {
                    drop(state);
                    let Some(mut s) = try_lock_global_state() else {
                        return -1;
                    };
                    set_error(&mut s, format!("Invalid statement ID: {}", stmt_id));
                    return -1;
                }
            }
        };

        let timeout_sec = if timeout_override_ms > 0 {
            Some(((timeout_override_ms as usize) / 1000).max(1))
        } else {
            stored_timeout_sec
        };
        let fetch_size_opt = if fetch_size > 0 {
            Some(fetch_size)
        } else {
            None
        };

        let execute_with_params = |params_slice: &[u8]| {
            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };

            let metrics = state::ffi_metrics();
            let start = Instant::now();

            let mut target = match take_runnable_connection(&mut state, conn_id) {
                Ok(target) => target,
                Err(e) => {
                    set_connection_structured_error(&mut state, conn_id, e.to_structured());
                    return -1;
                }
            };
            drop(state);

            let result = match &mut target {
                RunnableConnection::Regular(conn_arc) => {
                    let conn_guard = match conn_arc.lock() {
                        Ok(g) => g,
                        Err(_) => {
                            let Some(mut state) = try_lock_global_state() else {
                                return -1;
                            };
                            set_connection_error(
                                &mut state,
                                conn_id,
                                "Failed to lock connection".to_string(),
                            );
                            return -1;
                        }
                    };
                    execute_query_with_param_buffer_and_timeout(
                        conn_guard.connection(),
                        &sql_str,
                        params_slice,
                        timeout_sec,
                        fetch_size_opt,
                    )
                }
                RunnableConnection::Pooled { pooled, .. } => match pooled.lock() {
                    Ok(conn_guard) => execute_query_with_param_buffer_and_timeout(
                        conn_guard.get_connection(),
                        &sql_str,
                        params_slice,
                        timeout_sec,
                        fetch_size_opt,
                    ),
                    Err(_) => Err(OdbcError::InternalError(
                        "Failed to lock pooled connection".to_string(),
                    )),
                },
            };

            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };
            restore_pooled_connection(&mut state, conn_id, target);

            match result {
                Ok(data) => {
                    let elapsed = start.elapsed();
                    let status = write_connection_output_buffer(
                        &mut state,
                        conn_id,
                        &data,
                        out_buffer,
                        buffer_len,
                        out_written,
                    );
                    if status == FFI_OK {
                        metrics.record_query(elapsed);
                    } else {
                        metrics.record_error();
                    }
                    status
                }
                Err(e) => {
                    metrics.record_error();
                    set_connection_structured_error(&mut state, conn_id, e.to_structured());
                    -1
                }
            }
        };

        // SAFETY: FFI caller must keep `params_buffer` readable for this call.
        // The borrowed slice is scoped to the callback and never stored.
        match unsafe { with_optional_param_buffer(params_buffer, params_len, execute_with_params) }
        {
            Ok(status) => status,
            Err(message) => {
                let Some(mut state) = try_lock_global_state() else {
                    set_out_written_zero(out_written);
                    return -1;
                };
                set_invalid_param_buffer_error(&mut state, conn_id, message);
                set_out_written_zero(out_written);
                -1
            }
        }
    })
}

/// Cancel a statement in execution.
/// stmt_id: from odbc_prepare
/// Returns: 0 on success, non-zero on failure
///
/// # Unsupported Feature
///
/// Statement cancellation is not currently supported. This feature requires:
/// - Background execution thread with active statement handle tracking
/// - SQLCancel() or SQLCancelHandle() call on the executing statement
/// - Proper synchronization between execution and cancellation threads
///
/// Workaround: Use query timeout at connection or statement level instead.
#[no_mangle]
pub extern "C" fn odbc_cancel(stmt_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };

        if state.statements.contains_key(&stmt_id) {
            set_structured_error(
            &mut state,
            StructuredError {
                sqlstate: *b"0A000",
                native_code: CANCEL_UNSUPPORTED_NATIVE_CODE,
                message:
                    "Unsupported feature: Statement cancellation requires background execution. \
                Use query timeout (login_timeout or statement timeout) instead. \
                See project tracker for implementation status."
                        .to_string(),
            },
        );
            1
        } else {
            set_error(&mut state, format!("Invalid statement ID: {}", stmt_id));
            1
        }
    })
}

/// Close a prepared statement and release resources.
/// stmt_id: from odbc_prepare
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_close_statement(stmt_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };

        if state.statements.remove(&stmt_id).is_some() {
            0
        } else {
            set_error(&mut state, format!("Invalid statement ID: {}", stmt_id));
            1
        }
    })
}

/// Close all prepared statements and release resources.
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_clear_all_statements() -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };

        state.statements.clear();
        0
    })
}

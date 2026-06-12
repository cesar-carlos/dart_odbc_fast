use super::super::global::*;
use super::helpers::parse_sql_owned;

use std::os::raw::{c_char, c_int, c_uint};

/// Starts non-blocking query execution.
/// Returns request_id (>0) on success, 0 on failure.
#[no_mangle]
pub extern "C" fn odbc_execute_async(conn_id: c_uint, sql: *const c_char) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        let sql_str = match unsafe { parse_sql_owned(sql) } {
            Some(s) => s,
            None => return 0,
        };

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };

        if !state.connections.contains_key(&conn_id)
            && !state.pooled_connections.contains_key(&conn_id)
        {
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return 0;
        }

        drop(state);
        let Some(mut async_mgr) = lock_async_requests() else {
            return 0;
        };
        async_mgr
            .start_request(conn_id, sql_str, None, 0)
            .unwrap_or(0)
    })
}

/// Starts non-blocking parameterized query execution.
/// Returns request_id (>0) on success, 0 on failure or unavailable handle.
#[no_mangle]
pub extern "C" fn odbc_execute_async_params(
    conn_id: c_uint,
    sql: *const c_char,
    params_buffer: *const u8,
    params_len: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        // SAFETY: FFI caller owns `params_buffer`; this async path copies the
        // bytes before returning, so no foreign pointer is retained.
        let params_slice = match unsafe { read_param_buffer_owned(params_buffer, params_len) } {
            Ok(params_slice) => params_slice,
            Err(message) => {
                let Some(mut state) = try_lock_global_state() else {
                    return 0;
                };
                set_invalid_param_buffer_error(&mut state, conn_id, message);
                return 0;
            }
        };

        let sql_str = match unsafe { parse_sql_owned(sql) } {
            Some(s) => s,
            None => return 0,
        };

        let params = if params_slice.is_empty() {
            None
        } else {
            Some(params_slice)
        };

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };

        if !state.connections.contains_key(&conn_id)
            && !state.pooled_connections.contains_key(&conn_id)
        {
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return 0;
        }

        drop(state);
        let Some(mut async_mgr) = lock_async_requests() else {
            return 0;
        };
        async_mgr
            .start_request(conn_id, sql_str, params, 0)
            .unwrap_or(0)
    })
}

/// Like [odbc_execute_async_params] but selects binary result encoding for the
/// async task (`0` = row-major, `1` = columnar v2, `2` = columnar compressed).
/// Invalid encoding codes fall back to row-major.
#[no_mangle]
pub extern "C" fn odbc_execute_async_params_options(
    conn_id: c_uint,
    sql: *const c_char,
    params_buffer: *const u8,
    params_len: c_uint,
    result_encoding: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        // SAFETY: FFI caller owns `params_buffer`; this async path copies the
        // bytes before returning, so no foreign pointer is retained.
        let params_slice = match unsafe { read_param_buffer_owned(params_buffer, params_len) } {
            Ok(params_slice) => params_slice,
            Err(message) => {
                let Some(mut state) = try_lock_global_state() else {
                    return 0;
                };
                set_invalid_param_buffer_error(&mut state, conn_id, message);
                return 0;
            }
        };

        let sql_str = match unsafe { parse_sql_owned(sql) } {
            Some(s) => s,
            None => return 0,
        };

        let params = if params_slice.is_empty() {
            None
        } else {
            Some(params_slice)
        };

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };

        if !state.connections.contains_key(&conn_id)
            && !state.pooled_connections.contains_key(&conn_id)
        {
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return 0;
        }

        drop(state);
        // Sprint 3 split: async-request manager lives in its own Mutex
        // so spawning a request does not contend with the rest of the
        // FFI surface while the worker thread is still being installed.
        let Some(mut async_mgr) = lock_async_requests() else {
            return 0;
        };
        async_mgr
            .start_request(conn_id, sql_str, params, result_encoding)
            .unwrap_or(0)
    })
}

/// Poll async request status.
/// Returns 0 on success, -1 on invalid request/pointer.
/// out_status: 0=pending, 1=ready, -1=error, -2=cancelled
#[no_mangle]
pub extern "C" fn odbc_async_poll(request_id: c_uint, out_status: *mut c_int) -> c_int {
    crate::ffi_guard_int!({
        if out_status.is_null() {
            return -1;
        }

        let Some(async_mgr) = lock_async_requests() else {
            return -1;
        };

        match async_mgr.poll(request_id) {
            Some(status) => {
                // SAFETY: `out_status` is non-null (checked above).
                unsafe {
                    *out_status = status;
                }
                0
            }
            None => -1,
        }
    })
}

/// Gets async request result into caller-provided buffer.
/// Returns: 0 on success, -1 on error, -2 if buffer too small.
#[no_mangle]
pub extern "C" fn odbc_async_get_result(
    request_id: c_uint,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if out_buffer.is_null() || out_written.is_null() {
            return -1;
        }

        let Some(async_mgr) = lock_async_requests() else {
            set_out_written_zero(out_written);
            return -1;
        };

        let Some((conn_id, result)) = async_mgr.take_result(request_id) else {
            set_out_written_zero(out_written);
            return -1;
        };

        match result {
            Ok(data) => {
                let status = write_ffi_output_buffer(&data, out_buffer, buffer_len, out_written);
                if status == FFI_ERR_BUFFER_TOO_SMALL {
                    let _ = async_mgr.restore_result(request_id, Ok(data));
                }
                status
            }
            Err(e) => {
                // Drop async_mgr lock before grabbing global state to record the structured
                // error, preserving the canonical lock order (global → async).
                drop(async_mgr);
                let Some(mut state) = try_lock_global_state() else {
                    set_out_written_zero(out_written);
                    return -1;
                };
                set_connection_structured_error(&mut state, conn_id, e.to_structured());
                set_out_written_zero(out_written);
                -1
            }
        }
    })
}

/// Best-effort cancellation for async request.
/// Returns 0 on success, -1 if request is unknown.
#[no_mangle]
pub extern "C" fn odbc_async_cancel(request_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(async_mgr) = lock_async_requests() else {
            return -1;
        };
        if async_mgr.cancel(request_id) {
            0
        } else {
            -1
        }
    })
}

/// Frees async request resources.
/// Returns 0 on success, -1 if request is unknown.
#[no_mangle]
pub extern "C" fn odbc_async_free(request_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut async_mgr) = lock_async_requests() else {
            return -1;
        };
        if async_mgr.free(request_id) {
            0
        } else {
            -1
        }
    })
}

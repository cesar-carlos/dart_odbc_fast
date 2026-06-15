use super::super::super::global::*;
use super::super::super::prelude::*;
use super::super::helpers::{
    parse_sql_ptr, report_invalid_param_buffer, require_query_output_ptrs,
};
use crate::ffi::state;

use std::os::raw::{c_char, c_int, c_uint};

/// Execute parameterized query and return binary buffer
/// conn_id: connection ID
/// sql: null-terminated UTF-8 SQL query
/// params_buffer: serialized ParamValue array (NULL = no parameters)
/// params_len: length of params_buffer in bytes
/// out_buffer: output buffer (pre-allocated)
/// buffer_len: buffer size
/// out_written: actual bytes written
/// Returns: 0 on success, -1 on error, -2 if buffer too small
#[no_mangle]
pub extern "C" fn odbc_exec_query_params(
    conn_id: c_uint,
    sql: *const c_char,
    params_buffer: *const u8,
    params_len: c_uint,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if !require_query_output_ptrs(sql, out_buffer, out_written) {
            return -1;
        }

        // SAFETY: `sql` validated by `require_query_output_ptrs`; `parse_sql_ptr`
        // documents caller obligations for the NUL-terminated SQL pointer.
        let sql_str = match unsafe { parse_sql_ptr(sql) } {
            Some(s) => s,
            None => return -1,
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
                    set_out_written_zero(out_written);
                    return -1;
                }
            };
            drop(state);

            let result = match &mut target {
                RunnableConnection::Regular(conn_arc) => {
                    let mut conn_guard = match conn_arc.lock() {
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
                            set_out_written_zero(out_written);
                            return -1;
                        }
                    };
                    if params_slice.is_empty() {
                        execute_query_with_cached_connection(&mut conn_guard, sql_str)
                    } else {
                        try_cached_legacy_params(&mut conn_guard, sql_str, params_slice)
                    }
                }
                RunnableConnection::Pooled { pooled, .. } => match pooled.lock() {
                    Ok(mut conn_guard) => {
                        if params_slice.is_empty() {
                            execute_query_with_cached_connection(conn_guard.cached_mut(), sql_str)
                        } else {
                            try_cached_legacy_params(conn_guard.cached_mut(), sql_str, params_slice)
                        }
                    }
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
                    let structured = e.to_structured();
                    set_connection_structured_error(&mut state, conn_id, structured);
                    set_out_written_zero(out_written);
                    -1
                }
            }
        };

        // SAFETY: FFI caller must keep `params_buffer` readable for this call.
        match unsafe { with_optional_param_buffer(params_buffer, params_len, execute_with_params) }
        {
            Ok(status) => status,
            Err(message) => report_invalid_param_buffer(conn_id, message, out_written),
        }
    })
}

/// Execute parameterized query with an explicit result encoding.
///
/// result_encoding: 0=row-major v1, 1=columnar v2, 2=columnar v2 compressed.
/// Older Dart runtimes use `odbc_exec_query_params`; this additive symbol is
/// resolved dynamically by newer clients.
#[no_mangle]
pub extern "C" fn odbc_exec_query_params_options(
    conn_id: c_uint,
    sql: *const c_char,
    params_buffer: *const u8,
    params_len: c_uint,
    result_encoding: c_uint,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if !require_query_output_ptrs(sql, out_buffer, out_written) {
            return -1;
        }

        let encoding = match ResultEncoding::from_wire(result_encoding) {
            Some(encoding) => encoding,
            None => {
                set_out_written_zero(out_written);
                return -1;
            }
        };

        // SAFETY: `sql` validated by `require_query_output_ptrs`; `parse_sql_ptr`
        // documents caller obligations for the NUL-terminated SQL pointer.
        let sql_str = match unsafe { parse_sql_ptr(sql) } {
            Some(s) => s,
            None => return -1,
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
                    set_out_written_zero(out_written);
                    return -1;
                }
            };
            drop(state);

            let result = match &mut target {
                RunnableConnection::Regular(conn_arc) => {
                    let mut conn_guard = match conn_arc.lock() {
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
                            set_out_written_zero(out_written);
                            return -1;
                        }
                    };
                    if encoding == ResultEncoding::RowMajor && params_slice.is_empty() {
                        execute_query_with_cached_connection(&mut conn_guard, sql_str)
                    } else if encoding == ResultEncoding::RowMajor {
                        try_cached_legacy_params(&mut conn_guard, sql_str, params_slice)
                    } else {
                        execute_query_with_param_buffer_encoding(
                            conn_guard.connection(),
                            sql_str,
                            params_slice,
                            encoding,
                        )
                    }
                }
                RunnableConnection::Pooled { pooled, .. } => match pooled.lock() {
                    Ok(mut conn_guard) => {
                        if encoding == ResultEncoding::RowMajor && params_slice.is_empty() {
                            execute_query_with_cached_connection(conn_guard.cached_mut(), sql_str)
                        } else if encoding == ResultEncoding::RowMajor {
                            try_cached_legacy_params(conn_guard.cached_mut(), sql_str, params_slice)
                        } else {
                            execute_query_with_param_buffer_encoding(
                                conn_guard.get_connection(),
                                sql_str,
                                params_slice,
                                encoding,
                            )
                        }
                    }
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
                    let structured = e.to_structured();
                    set_connection_structured_error(&mut state, conn_id, structured);
                    set_out_written_zero(out_written);
                    -1
                }
            }
        };

        // SAFETY: FFI caller must keep `params_buffer` readable for this call.
        match unsafe { with_optional_param_buffer(params_buffer, params_len, execute_with_params) }
        {
            Ok(status) => status,
            Err(message) => report_invalid_param_buffer(conn_id, message, out_written),
        }
    })
}

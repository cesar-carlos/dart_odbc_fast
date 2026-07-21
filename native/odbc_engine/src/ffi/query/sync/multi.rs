use super::super::super::global::*;
use super::super::super::prelude::*;
use super::super::helpers::{
    parse_sql_ptr, report_invalid_param_buffer, require_query_output_ptrs,
};
use crate::ffi::state;

use std::os::raw::{c_char, c_int, c_uint};

/// Execute batch SQL (multi-result) and return binary buffer.
/// Same contract as `odbc_exec_query`; output is multi-result wire format
/// (v2 framing: magic + version + count + items).
///
/// Accepts both connection IDs from `odbc_connect` and pooled IDs from
/// `odbc_pool_get_connection` (M2 fix in v3.2.0).
///
/// Returns: 0 on success, -1 on error, -2 if buffer too small.
#[no_mangle]
pub extern "C" fn odbc_exec_query_multi(
    conn_id: c_uint,
    sql: *const c_char,
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

        let Some(mut state) = try_lock_global_state() else {
            set_out_written_zero(out_written);
            return -1;
        };

        state::ffi_audit_logger().log_query(conn_id, sql_str);

        let metrics = state::ffi_metrics();
        let start = Instant::now();
        let pending_key = state::PendingResultKey::ExecQueryMulti {
            conn_id,
            sql_hash: state::hash_bytes(sql_str.as_bytes()),
        };
        if let Some(code) =
            state::try_write_pending_result(&pending_key, out_buffer, buffer_len, out_written)
        {
            return code;
        }

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

        let result = match target_guard.target_mut() {
            RunnableConnection::Regular(conn_arc) => {
                let conn_guard = match conn_arc.lock() {
                    Ok(g) => g,
                    Err(_) => {
                        let Some(mut state) = try_lock_global_state() else {
                            set_out_written_zero(out_written);
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
                execute_multi_result(conn_guard.connection(), sql_str)
            }
            RunnableConnection::Pooled { pooled, .. } => match pooled.lock() {
                Ok(conn_guard) => execute_multi_result(conn_guard.get_connection(), sql_str),
                Err(_) => Err(OdbcError::InternalError(
                    "Failed to lock pooled connection".to_string(),
                )),
            },
        };

        let Some(mut state) = try_lock_global_state() else {
            set_out_written_zero(out_written);
            return -1;
        };
        restore_pooled_connection(&mut state, conn_id, target_guard.take_target());

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
                state::stash_if_buffer_too_small(status, pending_key, data)
            }
            Err(e) => {
                metrics.record_error();
                let structured = e.to_structured();
                set_connection_structured_error(&mut state, conn_id, structured);
                set_out_written_zero(out_written);
                -1
            }
        }
    })
}

/// Execute parameterised batch SQL (multi-result) and return binary buffer.
/// Same wire format as `odbc_exec_query_multi`. Accepts positional `?`
/// parameters serialized with the legacy ParamValue or DRT1 buffer formats.
///
/// Accepts both connection IDs from `odbc_connect` and pooled IDs from
/// `odbc_pool_get_connection`.
///
/// Returns: 0 on success, -1 on error, -2 if buffer too small.
#[no_mangle]
pub extern "C" fn odbc_exec_query_multi_params(
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

        // SAFETY: FFI caller must keep `params_buffer` readable while the
        // callback deserializes it. The borrowed slice is not stored.
        let params = match unsafe {
            with_optional_param_buffer(
                params_buffer,
                params_len,
                |params_slice| -> std::result::Result<Vec<ParamValue>, c_int> {
                    if params_slice.is_empty() {
                        Ok(vec![])
                    } else {
                        match deserialize_param_buffer(params_slice) {
                            Ok(ParamList::Legacy(p)) => Ok(p),
                            Ok(ParamList::Directed(b)) => {
                                if b.iter().any(|x| x.direction != ParamDirection::Input) {
                                    let Some(mut s) = try_lock_global_state() else {
                                        return Err(-1);
                                    };
                                    set_connection_error(
                                        &mut s,
                                        conn_id,
                                        "odbc_exec_query_multi_params: OUTPUT/INOUT not supported (use odbc_exec_query with DRT1)"
                                            .to_string(),
                                    );
                                    return Err(-1);
                                }
                                Ok(b.iter().map(|x| x.value.clone()).collect())
                            }
                            Err(e) => {
                                let Some(mut s) = try_lock_global_state() else {
                                    return Err(-1);
                                };
                                set_connection_error(
                                    &mut s,
                                    conn_id,
                                    format!("Invalid params: {}", e),
                                );
                                Err(-1)
                            }
                        }
                    }
                },
            )
        } {
            Ok(Ok(params)) => params,
            Ok(Err(status)) => {
                set_out_written_zero(out_written);
                return status;
            }
            Err(message) => {
                return report_invalid_param_buffer(conn_id, message, out_written);
            }
        };

        let Some(mut state) = try_lock_global_state() else {
            set_out_written_zero(out_written);
            return -1;
        };

        state::ffi_audit_logger().log_query(conn_id, sql_str);

        let metrics = state::ffi_metrics();
        let start = Instant::now();
        let pending_key = state::PendingResultKey::ExecQueryMulti {
            conn_id,
            sql_hash: state::hash_bytes(sql_str.as_bytes()),
        };
        if let Some(code) =
            state::try_write_pending_result(&pending_key, out_buffer, buffer_len, out_written)
        {
            return code;
        }

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

        let result = match target_guard.target_mut() {
            RunnableConnection::Regular(conn_arc) => {
                let conn_guard = match conn_arc.lock() {
                    Ok(g) => g,
                    Err(_) => {
                        let Some(mut state) = try_lock_global_state() else {
                            set_out_written_zero(out_written);
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
                execute_multi_result_with_params(conn_guard.connection(), sql_str, &params)
            }
            RunnableConnection::Pooled { pooled, .. } => match pooled.lock() {
                Ok(conn_guard) => {
                    execute_multi_result_with_params(conn_guard.get_connection(), sql_str, &params)
                }
                Err(_) => Err(OdbcError::InternalError(
                    "Failed to lock pooled connection".to_string(),
                )),
            },
        };

        let Some(mut state) = try_lock_global_state() else {
            set_out_written_zero(out_written);
            return -1;
        };
        restore_pooled_connection(&mut state, conn_id, target_guard.take_target());

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
                state::stash_if_buffer_too_small(status, pending_key, data)
            }
            Err(e) => {
                metrics.record_error();
                let structured = e.to_structured();
                set_connection_structured_error(&mut state, conn_id, structured);
                set_out_written_zero(out_written);
                -1
            }
        }
    })
}

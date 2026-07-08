use super::super::super::global::*;
use super::super::super::prelude::*;
use super::super::helpers::{parse_sql_ptr_zero_out, require_query_output_ptrs};
use crate::ffi::state;

use std::os::raw::{c_char, c_int, c_uint};

#[no_mangle]
pub extern "C" fn odbc_exec_query(
    conn_id: c_uint,
    sql: *const c_char,
    out_buf: *mut u8,
    buf_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if !require_query_output_ptrs(sql, out_buf, out_written) {
            return -1;
        }

        // SAFETY: `sql` validated by `require_query_output_ptrs`; `parse_sql_ptr_zero_out`
        // documents caller obligations for the NUL-terminated SQL pointer.
        let sql_str = match unsafe { parse_sql_ptr_zero_out(sql, out_written) } {
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
                let mut conn_guard = match conn_arc.lock() {
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
                execute_query_with_cached_connection(&mut conn_guard, sql_str)
            }
            RunnableConnection::Pooled { pooled, .. } => match pooled.lock() {
                Ok(mut conn_guard) => {
                    execute_query_with_cached_connection(conn_guard.cached_mut(), sql_str)
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
                    out_buf,
                    buf_len,
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
                let error_message = state::get_connection_error_message(conn_id)
                    .unwrap_or_else(|| "Query execution failed".to_string());
                state::ffi_audit_logger().log_error(Some(conn_id), &error_message);
                set_out_written_zero(out_written);
                -1
            }
        }
    })
}

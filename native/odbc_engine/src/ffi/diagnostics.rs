// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use super::global::*;
use crate::ffi::state;

use std::os::raw::{c_char, c_int, c_uint};

#[no_mangle]
pub extern "C" fn odbc_get_error(buffer: *mut c_char, buffer_len: c_uint) -> c_int {
    crate::ffi_guard_int!({
        if buffer.is_null() || buffer_len == 0 {
            return -1;
        }

        let Some(state) = try_lock_global_state() else {
            return -1;
        };

        let error_msg = get_connection_error(&state, None);
        let msg_bytes = error_msg.as_bytes();
        let copy_len = (msg_bytes.len() as c_uint).min(buffer_len - 1);

        // SAFETY: `buffer` is non-null (checked above), writable for `buffer_len`
        // bytes, and `copy_len < buffer_len`; `buffer.add(copy_len)` points to the
        // null-terminator slot which is within the allocation.
        unsafe {
            std::ptr::copy_nonoverlapping(msg_bytes.as_ptr(), buffer as *mut u8, copy_len as usize);
            *buffer.add(copy_len as usize) = 0;
        }

        copy_len as c_int
    })
}

/// Get last structured error
/// buffer: output buffer for serialized error
/// buffer_len: buffer size in bytes
/// out_written: actual bytes written
/// Returns: 0 on success, non-zero on error
#[no_mangle]
pub extern "C" fn odbc_get_structured_error(
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if buffer.is_null() || out_written.is_null() {
            return -1;
        }

        let Some(state) = try_lock_global_state() else {
            set_out_written_zero(out_written);
            return -1;
        };

        let Some(structured_error) = get_connection_structured_error(&state, None) else {
            // No structured error available.
            // Keep explicit contract: caller can fallback to odbc_get_error().
            // SAFETY: `out_written` is non-null (checked above).
            unsafe {
                *out_written = 0;
            }
            return 1;
        };

        let error_data = structured_error.serialize();

        if error_data.len() > buffer_len as usize {
            set_out_written_needed(out_written, error_data.len());
            return -2;
        }

        // SAFETY: `buffer` and `out_written` are non-null (checked above);
        // `error_data.len() <= buffer_len` (checked above); `buffer` is writable
        // for `buffer_len` bytes per the caller's FFI contract.
        unsafe {
            std::ptr::copy_nonoverlapping(error_data.as_ptr(), buffer, error_data.len());
            *out_written = error_data.len() as c_uint;
        }

        0
    })
}

/// Get structured error for a specific connection.
/// conn_id: connection ID (0 = use global fallback, same as odbc_get_structured_error)
/// buffer: output buffer for serialized error
/// buffer_len: buffer size in bytes
/// out_written: actual bytes written
/// Returns: 0 on success, 1 if no structured error for this connection, -1 on error, -2 if buffer too small
#[no_mangle]
pub extern "C" fn odbc_get_structured_error_for_connection(
    conn_id: c_uint,
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if buffer.is_null() || out_written.is_null() {
            return -1;
        }

        let Some(state) = try_lock_global_state() else {
            set_out_written_zero(out_written);
            return -1;
        };

        let conn_filter = if conn_id == 0 { None } else { Some(conn_id) };

        let Some(structured_error) = get_connection_structured_error(&state, conn_filter) else {
            // SAFETY: `out_written` is non-null (checked above).
            unsafe {
                *out_written = 0;
            }
            return 1;
        };

        let error_data = structured_error.serialize();

        if error_data.len() > buffer_len as usize {
            set_out_written_needed(out_written, error_data.len());
            return -2;
        }

        // SAFETY: `buffer` and `out_written` are non-null (checked above);
        // `error_data.len() <= buffer_len` (checked above).
        unsafe {
            std::ptr::copy_nonoverlapping(error_data.as_ptr(), buffer, error_data.len());
            *out_written = error_data.len() as c_uint;
        }

        0
    })
}

/// Get metrics: query count, error count, uptime, latencies.
/// Writes 40 bytes (5 u64 LE) to buffer: query_count, error_count,
/// uptime_secs, total_latency_millis, avg_latency_millis.
/// Returns 0 on success, -1 on error, -2 if buffer too small.
#[no_mangle]
pub extern "C" fn odbc_get_metrics(
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if buffer.is_null() || out_written.is_null() {
            return -1;
        }
        if buffer_len < 40 {
            set_out_written_needed(out_written, 40);
            return -2;
        }
        // Sprint 3 split: metrics is lock-free; no need to acquire the
        // outer GlobalState mutex just to read it.
        let metrics = state::ffi_metrics();
        let q = metrics.get_query_metrics();
        let ec = metrics.get_error_count();
        let up = metrics.uptime();
        let tm = q.total_latency.as_millis().min(u64::MAX as u128) as u64;
        let am = q.average_latency().as_millis().min(u64::MAX as u128) as u64;
        let mut p = [0u8; 40];
        p[0..8].copy_from_slice(&q.query_count.to_le_bytes());
        p[8..16].copy_from_slice(&ec.to_le_bytes());
        p[16..24].copy_from_slice(&up.as_secs().to_le_bytes());
        p[24..32].copy_from_slice(&tm.to_le_bytes());
        p[32..40].copy_from_slice(&am.to_le_bytes());
        // SAFETY: `buffer` and `out_written` are non-null (checked above);
        // buffer has at least 40 bytes (checked above); the local array `p` is
        // stack-allocated and aligned for `u8`.
        unsafe {
            std::ptr::copy_nonoverlapping(p.as_ptr(), buffer, 40);
            *out_written = 40;
        }
        0
    })
}

/// Enable or disable audit logging.
/// enabled: 0 = disable, non-zero = enable
/// Returns: 0 on success, -1 on failure
#[no_mangle]
pub extern "C" fn odbc_audit_enable(enabled: c_int) -> c_int {
    crate::ffi_guard_int!({
        // Sprint 3 split: audit logger is lock-free Arc; no outer lock needed.
        state::ffi_audit_logger().set_enabled(enabled != 0);
        0
    })
}

/// Get audit events as JSON array.
/// Returns: 0 on success, -1 on error, -2 if buffer too small
#[no_mangle]
pub extern "C" fn odbc_audit_get_events(
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
    limit: c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if buffer.is_null() || out_written.is_null() {
            return -1;
        }

        if buffer_len == 0 {
            set_out_written_zero(out_written);
            return -1;
        }

        let take_limit: usize = if limit == 0 {
            usize::MAX
        } else {
            limit as usize
        };
        // Sprint 3 split: audit logger is lock-free Arc.
        let events = state::ffi_audit_logger().get_events(take_limit);

        let data = match serialize_audit_events(events) {
            Ok(bytes) => bytes,
            Err(_) => {
                set_out_written_zero(out_written);
                return -1;
            }
        };

        write_ffi_output_buffer(&data, buffer, buffer_len, out_written)
    })
}

/// Clear all audit events.
/// Returns: 0 on success, -1 on failure
#[no_mangle]
pub extern "C" fn odbc_audit_clear() -> c_int {
    crate::ffi_guard_int!({
        // Sprint 3 split: audit logger is lock-free Arc.
        state::ffi_audit_logger().clear_events();
        0
    })
}

/// Get audit status as JSON object.
/// Returns: 0 on success, -1 on error, -2 if buffer too small
#[no_mangle]
pub extern "C" fn odbc_audit_get_status(
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if buffer.is_null() || out_written.is_null() {
            return -1;
        }

        if buffer_len == 0 {
            set_out_written_zero(out_written);
            return -1;
        }

        let Some(state) = try_lock_global_state() else {
            set_out_written_zero(out_written);
            return -1;
        };

        let data = match serialize_audit_status(&state::ffi_audit_logger()) {
            Ok(bytes) => bytes,
            Err(_) => {
                set_out_written_zero(out_written);
                return -1;
            }
        };
        drop(state);

        write_ffi_output_buffer(&data, buffer, buffer_len, out_written)
    })
}

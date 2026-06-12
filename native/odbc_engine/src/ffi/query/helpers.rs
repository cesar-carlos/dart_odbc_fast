use super::super::global::*;
use super::super::global_state::set_out_written_zero;
use crate::ffi::guard;

use std::os::raw::{c_char, c_int, c_uint};

/// Validates required output pointers for sync query entry points.
pub(crate) fn require_query_output_ptrs(
    sql: *const c_char,
    out_buffer: *mut u8,
    out_written: *mut c_uint,
) -> bool {
    !sql.is_null() && !out_buffer.is_null() && !out_written.is_null()
}

/// Parses a NUL-terminated UTF-8 SQL pointer from the FFI caller.
///
/// # Safety
///
/// When `sql` is non-null, the caller must guarantee it points to a valid
/// NUL-terminated C string that remains readable for the duration of the borrow.
pub(crate) unsafe fn parse_sql_ptr<'a>(sql: *const c_char) -> Option<&'a str> {
    let c_str = guard::ptr_to_cstr(sql)?;
    c_str.to_str().ok()
}

/// Like [`parse_sql_ptr`] but zeroes `out_written` before returning `None`.
///
/// # Safety
///
/// Same obligations as [`parse_sql_ptr`]; `out_written` may be written when
/// parsing fails.
pub(crate) unsafe fn parse_sql_ptr_zero_out<'a>(
    sql: *const c_char,
    out_written: *mut c_uint,
) -> Option<&'a str> {
    match unsafe { parse_sql_ptr(sql) } {
        Some(sql_str) => Some(sql_str),
        None => {
            set_out_written_zero(out_written);
            None
        }
    }
}

/// Copies a validated SQL pointer into an owned `String` for async work.
///
/// # Safety
///
/// Same obligations as [`parse_sql_ptr`].
pub(crate) unsafe fn parse_sql_owned(sql: *const c_char) -> Option<String> {
    parse_sql_ptr(sql).map(str::to_owned)
}

pub(crate) fn report_invalid_param_buffer(
    conn_id: c_uint,
    message: &'static str,
    out_written: *mut c_uint,
) -> c_int {
    let Some(mut state) = try_lock_global_state() else {
        set_out_written_zero(out_written);
        return -1;
    };
    set_invalid_param_buffer_error(&mut state, conn_id, message);
    set_out_written_zero(out_written);
    -1
}

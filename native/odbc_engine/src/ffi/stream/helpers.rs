use super::super::global::*;
use super::super::global_state::{
    set_out_written_needed, GlobalState, DEFAULT_CHUNK_SIZE, DEFAULT_FETCH_SIZE,
};
use crate::ffi::guard;
use crate::ffi::prelude::StreamCopyResult;

use std::os::raw::{c_char, c_int, c_uint};

/// Parses a NUL-terminated UTF-8 SQL pointer for stream entry points.
pub(crate) fn parse_stream_sql<'a>(sql: *const c_char) -> Option<&'a str> {
    if sql.is_null() {
        return None;
    }
    // SAFETY: `sql` is non-null; caller guarantees a valid NUL-terminated C string.
    let c_str = unsafe { guard::ptr_to_cstr(sql)? };
    c_str.to_str().ok()
}

pub(crate) fn resolve_chunk_size(chunk_size: c_uint) -> usize {
    if chunk_size > 0 {
        chunk_size as usize
    } else {
        DEFAULT_CHUNK_SIZE as usize
    }
}

pub(crate) fn resolve_fetch_size(fetch_size: c_uint) -> usize {
    if fetch_size > 0 {
        fetch_size as usize
    } else {
        DEFAULT_FETCH_SIZE as usize
    }
}

pub(crate) fn require_stream_fetch_ptrs(
    out_buf: *mut u8,
    out_written: *mut c_uint,
    has_more: *mut u8,
) -> bool {
    !out_buf.is_null() && !out_written.is_null() && !has_more.is_null()
}

/// # Safety
///
/// `out_written` and `has_more` must be non-null and writable.
pub(crate) unsafe fn write_stream_fetch_copied(
    out_written: *mut c_uint,
    has_more: *mut u8,
    written: usize,
    more: bool,
) {
    // SAFETY: validated non-null by caller.
    unsafe {
        *out_written = written as c_uint;
        *has_more = if more { 1 } else { 0 };
    }
}

/// # Safety
///
/// `out_written` and `has_more` must be non-null and writable.
pub(crate) unsafe fn write_stream_fetch_end(out_written: *mut c_uint, has_more: *mut u8) {
    // SAFETY: validated non-null by caller.
    unsafe {
        *out_written = 0;
        *has_more = 0;
    }
}

pub(crate) fn apply_stream_fetch_result(
    state: &mut GlobalState,
    stream_conn_id: Option<u32>,
    buf_len: c_uint,
    out_written: *mut c_uint,
    has_more: *mut u8,
    fetch_result: crate::error::Result<StreamCopyResult>,
) -> c_int {
    match fetch_result {
        Ok(StreamCopyResult::Copied {
            written,
            has_more: more,
        }) => {
            // SAFETY: `out_written` and `has_more` are non-null (checked by caller).
            unsafe { write_stream_fetch_copied(out_written, has_more, written, more) };
            0
        }
        Ok(StreamCopyResult::BufferTooSmall { needed }) => {
            let message = format!("Buffer too small: need {} bytes, got {}", needed, buf_len);
            if let Some(conn_id) = stream_conn_id {
                set_connection_error(state, conn_id, message);
            } else {
                set_error(state, message);
            }
            set_out_written_needed(out_written, needed);
            // SAFETY: `has_more` is non-null (checked by caller).
            unsafe {
                *has_more = 1;
            }
            -2
        }
        Ok(StreamCopyResult::End) => {
            // SAFETY: `out_written` and `has_more` are non-null (checked by caller).
            unsafe { write_stream_fetch_end(out_written, has_more) };
            0
        }
        Err(e) => {
            let message = format!("odbc_stream_fetch failed: {}", e);
            if let Some(conn_id) = stream_conn_id {
                set_connection_error(state, conn_id, message);
            } else {
                set_error(state, message);
            }
            -1
        }
    }
}

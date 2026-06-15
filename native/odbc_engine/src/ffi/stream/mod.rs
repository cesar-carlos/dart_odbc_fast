// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

mod adapter;
mod helpers;

use super::global::*;
use crate::ffi::state;
use helpers::{apply_stream_fetch_result, require_stream_fetch_ptrs};

use std::os::raw::{c_char, c_int, c_uint};

/// Start streaming query execution.
#[no_mangle]
pub extern "C" fn odbc_stream_start(
    conn_id: c_uint,
    sql: *const c_char,
    chunk_size: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, { adapter::stream_start(conn_id, sql, chunk_size) })
}

/// Start batched streaming (cursor-based; bounded memory).
#[no_mangle]
pub extern "C" fn odbc_stream_start_batched(
    conn_id: c_uint,
    sql: *const c_char,
    fetch_size: c_uint,
    chunk_size: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        adapter::stream_start_batched(conn_id, sql, fetch_size, chunk_size)
    })
}

/// Start batched streaming with an explicit result wire encoding (v4.2).
#[no_mangle]
pub extern "C" fn odbc_stream_start_batched_options(
    conn_id: c_uint,
    sql: *const c_char,
    fetch_size: c_uint,
    chunk_size: c_uint,
    result_encoding: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        adapter::stream_start_batched_options(conn_id, sql, fetch_size, chunk_size, result_encoding)
    })
}

/// Start async batched stream execution.
#[no_mangle]
pub extern "C" fn odbc_stream_start_async(
    conn_id: c_uint,
    sql: *const c_char,
    fetch_size: c_uint,
    chunk_size: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        adapter::stream_start_async(conn_id, sql, fetch_size, chunk_size)
    })
}

/// Start async batched stream execution with explicit wire encoding.
#[no_mangle]
pub extern "C" fn odbc_stream_start_async_options(
    conn_id: c_uint,
    sql: *const c_char,
    fetch_size: c_uint,
    chunk_size: c_uint,
    result_encoding: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        adapter::stream_start_async_options(conn_id, sql, fetch_size, chunk_size, result_encoding)
    })
}

/// Start a streaming **multi-result** batch (M8 in v3.3.0).
#[no_mangle]
pub extern "C" fn odbc_stream_multi_start_batched(
    conn_id: c_uint,
    sql: *const c_char,
    chunk_size: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        adapter::stream_multi_start_batched(conn_id, sql, chunk_size)
    })
}

/// Async variant of [`odbc_stream_multi_start_batched`].
#[no_mangle]
pub extern "C" fn odbc_stream_multi_start_async(
    conn_id: c_uint,
    sql: *const c_char,
    chunk_size: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        adapter::stream_multi_start_async(conn_id, sql, chunk_size)
    })
}

/// Multi-result batched streaming with explicit wire encoding.
#[no_mangle]
pub extern "C" fn odbc_stream_multi_start_batched_options(
    conn_id: c_uint,
    sql: *const c_char,
    fetch_size: c_uint,
    chunk_size: c_uint,
    result_encoding: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        adapter::stream_multi_start_batched_options(
            conn_id,
            sql,
            fetch_size,
            chunk_size,
            result_encoding,
        )
    })
}

/// Multi-result async batched streaming with explicit wire encoding.
#[no_mangle]
pub extern "C" fn odbc_stream_multi_start_async_options(
    conn_id: c_uint,
    sql: *const c_char,
    fetch_size: c_uint,
    chunk_size: c_uint,
    result_encoding: u32,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        adapter::stream_multi_start_async_options(
            conn_id,
            sql,
            fetch_size,
            chunk_size,
            result_encoding,
        )
    })
}

/// Poll async stream status.
#[no_mangle]
pub extern "C" fn odbc_stream_poll_async(stream_id: c_uint, out_status: *mut c_int) -> c_int {
    crate::ffi_guard_int!({
        if out_status.is_null() {
            return -1;
        }

        let status = match state::with_stream_mut(stream_id, |stream| stream.poll_status()) {
            Some(status) => status,
            None => {
                if let Some(mut gs) = try_lock_global_state() {
                    set_error(&mut gs, format!("Invalid stream ID: {}", stream_id));
                }
                return -1;
            }
        };

        // SAFETY: `out_status` is non-null (checked above).
        unsafe {
            *out_status = status;
        }
        0
    })
}

/// Fetch next chunk from stream
#[no_mangle]
pub extern "C" fn odbc_stream_fetch(
    stream_id: c_uint,
    out_buf: *mut u8,
    buf_len: c_uint,
    out_written: *mut c_uint,
    has_more: *mut u8,
) -> c_int {
    crate::ffi_guard_int!({
        if !require_stream_fetch_ptrs(out_buf, out_written, has_more) {
            return -1;
        }

        let stream_conn_id = state::stream_connection_id(stream_id);

        let mut stream = match state::remove_stream(stream_id) {
            Some(s) => s,
            None => {
                if let Some(mut gs) = try_lock_global_state() {
                    set_error(&mut gs, format!("Invalid stream ID: {}", stream_id));
                }
                return -1;
            }
        };

        // SAFETY: `out_buf` is non-null (checked above); caller guarantees the
        // buffer is writable for `buf_len` bytes for the duration of this call.
        let out_slice = unsafe { std::slice::from_raw_parts_mut(out_buf, buf_len as usize) };
        let fetch_result = stream.copy_next_chunk(out_slice);

        state::reinsert_stream(stream_id, stream);

        let Some(mut gs) = try_lock_global_state() else {
            return -1;
        };

        apply_stream_fetch_result(
            &mut gs,
            stream_conn_id,
            buf_len,
            out_written,
            has_more,
            fetch_result,
        )
    })
}

/// Request cancellation of a batched stream.
#[no_mangle]
pub extern "C" fn odbc_stream_cancel(stream_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        if state::request_stream_cancel(stream_id) {
            0
        } else if let Some(mut gs) = try_lock_global_state() {
            set_error(&mut gs, format!("Invalid stream ID: {}", stream_id));
            1
        } else {
            -1
        }
    })
}

/// Close stream
#[no_mangle]
pub extern "C" fn odbc_stream_close(stream_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        if state::close_stream(stream_id) {
            0
        } else if let Some(mut gs) = try_lock_global_state() {
            set_error(&mut gs, format!("Invalid stream ID: {}", stream_id));
            1
        } else {
            -1
        }
    })
}

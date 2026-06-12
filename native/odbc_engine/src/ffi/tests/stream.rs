//! FFI `stream` tests.

#![allow(unused_imports)]

use crate::ffi::bulk::row_chunk_ranges;
#[cfg(feature = "sqlserver-bcp")]
use crate::ffi::bulk::slice_payload_rows;
use crate::ffi::connection::validate_connection_string_format;
use crate::ffi::global::*;
use crate::ffi::prelude::*;
use crate::ffi::state;
use crate::ffi::xa::xa_read_buffer;
use crate::ffi::*;
use crate::protocol::{
    serialize_bulk_insert_payload, serialize_bulk_insert_payload_v2, serialize_params,
    BulkColumnData, BulkColumnSpec, BulkColumnType, BulkInsertPayload, ParamValue,
};
use serde_json::Value;
use serial_test::serial;
use std::ffi::CString;
use std::os::raw::{c_char, c_int, c_uint};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Barrier, Mutex, OnceLock};
use std::time::Duration;

use super::support::{
    ffi_test_dsn, ffi_test_dsn_is_sql_server, get_last_error, next_test_invalid_id,
    structured_error_test_lock, trigger_structured_cancel_unsupported_error,
    with_structured_error_test_isolation, TEST_INVALID_ID,
};

#[test]
fn test_ffi_stream_start_null_sql() {
    odbc_init();

    let stream_id = odbc_stream_start(1, std::ptr::null(), 100);

    assert_eq!(stream_id, 0, "Null SQL should return 0");
}

#[test]
fn test_ffi_stream_start_invalid_conn() {
    odbc_init();

    let sql = CString::new("SELECT 1").unwrap();
    let stream_id = odbc_stream_start(TEST_INVALID_ID, sql.as_ptr(), 100);

    assert_eq!(stream_id, 0, "Invalid connection should return 0");
}

#[test]
fn test_ffi_stream_fetch_invalid_stream() {
    odbc_init();

    let invalid_id = next_test_invalid_id();
    let mut buffer = vec![0u8; 1024];
    let mut written: c_uint = 0;
    let mut has_more: u8 = 0;

    let result = odbc_stream_fetch(
        invalid_id,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
        &mut has_more,
    );

    assert_eq!(result, -1, "Invalid stream ID should return -1");

    let error = get_last_error();
    assert!(
        error.contains("Invalid stream ID") || error.contains("Invalid"),
        "Error should mention invalid stream: {}",
        error
    );
}

#[test]
fn test_ffi_stream_fetch_null_buffer() {
    let mut written: c_uint = 0;
    let mut has_more: u8 = 0;

    let result = odbc_stream_fetch(1, std::ptr::null_mut(), 1024, &mut written, &mut has_more);

    assert_eq!(result, -1, "Null buffer should return -1");
}

#[test]
fn test_ffi_stream_close_invalid_id() {
    odbc_init();

    let result = odbc_stream_close(TEST_INVALID_ID);
    assert_ne!(result, 0, "Invalid stream ID should fail");
}

#[test]
fn test_ffi_stream_start_batched_null_sql() {
    odbc_init();

    let stream_id = odbc_stream_start_batched(1, std::ptr::null(), 100, 1024);

    assert_eq!(stream_id, 0, "Null SQL should return 0");
}

#[test]
fn test_ffi_stream_start_batched_invalid_conn() {
    odbc_init();

    let sql = CString::new("SELECT 1").unwrap();
    let stream_id = odbc_stream_start_batched(TEST_INVALID_ID, sql.as_ptr(), 100, 1024);

    assert_eq!(stream_id, 0, "Invalid connection should return 0");
}

#[test]
fn test_ffi_stream_start_async_null_sql() {
    odbc_init();

    let stream_id = odbc_stream_start_async(1, std::ptr::null(), 100, 1024);
    assert_eq!(stream_id, 0, "Null SQL should return 0");
}

#[test]
fn test_ffi_stream_start_async_invalid_conn() {
    odbc_init();

    let sql = CString::new("SELECT 1").unwrap();
    let stream_id = odbc_stream_start_async(TEST_INVALID_ID, sql.as_ptr(), 100, 1024);
    assert_eq!(stream_id, 0, "Invalid connection should return 0");
}

#[test]
fn test_ffi_stream_poll_async_null_out_status() {
    let result = odbc_stream_poll_async(1, std::ptr::null_mut());
    assert_eq!(result, -1, "Null out_status should return -1");
}

#[test]
fn test_ffi_stream_poll_async_invalid_stream() {
    odbc_init();
    let mut status: c_int = 0;
    let result = odbc_stream_poll_async(TEST_INVALID_ID, &mut status);
    assert_eq!(result, -1, "Invalid stream_id should return -1");
}

#[test]
fn test_ffi_stream_fetch_null_has_more() {
    let mut buffer = vec![0u8; 1024];
    let mut written: c_uint = 0;

    let result = odbc_stream_fetch(
        1,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
        std::ptr::null_mut(),
    );

    assert_eq!(result, -1, "Null has_more should return -1");
}

#[test]
fn test_ffi_stream_fetch_null_out_written() {
    let mut buffer = vec![0u8; 1024];
    let mut has_more: u8 = 0;

    let result = odbc_stream_fetch(
        1,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        std::ptr::null_mut(),
        &mut has_more,
    );

    assert_eq!(result, -1, "Null out_written should return -1");
}

#[test]
fn test_ffi_streaming_workflow() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let sql = CString::new("SELECT 1 AS n").unwrap();
    let stream_id = odbc_stream_start(conn_id, sql.as_ptr(), 1024);
    assert!(stream_id > 0);

    let mut buffer = vec![0u8; 4096];
    let mut written: c_uint = 0;
    let mut has_more: u8 = 1;

    while has_more != 0 {
        let fr = odbc_stream_fetch(
            stream_id,
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
            &mut has_more,
        );
        assert_eq!(fr, 0, "Stream fetch should succeed");
        if has_more == 0 {
            break;
        }
    }

    let sr = odbc_stream_close(stream_id);
    assert_eq!(sr, 0);

    let dr = odbc_disconnect(conn_id);
    assert_eq!(dr, 0);
}

#[test]
fn test_ffi_stream_start_default_chunk_size_when_zero() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let sql = CString::new("SELECT 1 AS n").unwrap();
    let stream_id = odbc_stream_start(conn_id, sql.as_ptr(), 0);
    assert!(stream_id > 0, "chunk_size 0 should use DEFAULT_CHUNK_SIZE");

    let mut buffer = vec![0u8; 4096];
    let mut written: c_uint = 0;
    let mut has_more: u8 = 1;

    while has_more != 0 {
        let fr = odbc_stream_fetch(
            stream_id,
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
            &mut has_more,
        );
        assert_eq!(fr, 0, "Stream fetch should succeed");
        if has_more == 0 {
            break;
        }
    }

    let sr = odbc_stream_close(stream_id);
    assert_eq!(sr, 0);

    let dr = odbc_disconnect(conn_id);
    assert_eq!(dr, 0);
}

#[test]
fn test_ffi_stream_batched_workflow() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let sql = CString::new("SELECT 1 AS n").unwrap();
    let stream_id = odbc_stream_start_batched(
        conn_id,
        sql.as_ptr(),
        100,  /* fetch_size */
        1024, /* chunk_size */
    );
    assert!(stream_id > 0);

    let mut buffer = vec![0u8; 4096];
    let mut written: c_uint = 0;
    let mut has_more: u8 = 1;

    while has_more != 0 {
        let fr = odbc_stream_fetch(
            stream_id,
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
            &mut has_more,
        );
        assert_eq!(fr, 0, "Stream fetch should succeed");
        if has_more == 0 {
            break;
        }
    }

    let sr = odbc_stream_close(stream_id);
    assert_eq!(sr, 0);

    let dr = odbc_disconnect(conn_id);
    assert_eq!(dr, 0);
}

#[test]
fn test_ffi_stream_batched_defaults_when_zero() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let sql = CString::new("SELECT 1 AS n").unwrap();
    let stream_id = odbc_stream_start_batched(
        conn_id,
        sql.as_ptr(),
        0, /* fetch_size: 0 => DEFAULT_FETCH_SIZE */
        0, /* chunk_size: 0 => DEFAULT_CHUNK_SIZE */
    );
    assert!(stream_id > 0, "Defaults should work when 0,0 passed");

    let mut buffer = vec![0u8; 4096];
    let mut written: c_uint = 0;
    let mut has_more: u8 = 1;

    while has_more != 0 {
        let fr = odbc_stream_fetch(
            stream_id,
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
            &mut has_more,
        );
        assert_eq!(fr, 0, "Stream fetch should succeed");
        if has_more == 0 {
            break;
        }
    }

    let sr = odbc_stream_close(stream_id);
    assert_eq!(sr, 0);

    let dr = odbc_disconnect(conn_id);
    assert_eq!(dr, 0);
}

#[test]
fn test_ffi_stream_fetch_retry_preserves_chunk_after_buffer_too_small() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let large_literal = "X".repeat(3000);
    let sql_text = format!("SELECT '{}' AS large_text", large_literal);
    let sql = CString::new(sql_text).unwrap();

    // Use large chunk_size so first fetch chunk is larger than tiny buffer.
    let stream_id = odbc_stream_start(conn_id, sql.as_ptr(), 8192);
    assert!(stream_id > 0);

    let mut small_buffer = vec![0u8; 1024];
    let mut written: c_uint = 0;
    let mut has_more: u8 = 1;
    let small_result = odbc_stream_fetch(
        stream_id,
        small_buffer.as_mut_ptr(),
        small_buffer.len() as c_uint,
        &mut written,
        &mut has_more,
    );
    assert_eq!(small_result, -2, "Expected buffer-too-small on first fetch");
    assert!(
        written > small_buffer.len() as c_uint,
        "out_written must report required bytes on -2 (got {written})"
    );

    let mut larger_buffer = vec![0u8; 8192];
    let retry_result = odbc_stream_fetch(
        stream_id,
        larger_buffer.as_mut_ptr(),
        larger_buffer.len() as c_uint,
        &mut written,
        &mut has_more,
    );
    assert_eq!(retry_result, 0, "Retry with larger buffer should succeed");
    assert!(written > 0, "Retry must return preserved chunk bytes");

    while has_more != 0 {
        let next = odbc_stream_fetch(
            stream_id,
            larger_buffer.as_mut_ptr(),
            larger_buffer.len() as c_uint,
            &mut written,
            &mut has_more,
        );
        assert_eq!(next, 0, "Subsequent fetches should succeed");
    }

    let sr = odbc_stream_close(stream_id);
    assert_eq!(sr, 0);

    let dr = odbc_disconnect(conn_id);
    assert_eq!(dr, 0);
}

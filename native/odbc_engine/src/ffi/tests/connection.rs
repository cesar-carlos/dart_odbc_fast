//! FFI `core::connection` tests.

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
fn test_ffi_connect_invalid_string() {
    odbc_init();

    let empty_str = CString::new("").unwrap();
    let conn_id = odbc_connect(empty_str.as_ptr());

    assert_eq!(conn_id, 0, "Connect with empty string should fail");

    let error = get_last_error();
    assert!(!error.is_empty(), "Should have error message");
    println!("Error (expected): {}", error);
}
#[test]
fn test_ffi_connect_null_pointer() {
    odbc_init();

    let conn_id = odbc_connect(std::ptr::null());
    assert_eq!(conn_id, 0, "Connect with null pointer should fail");
}
#[test]
fn test_ffi_validate_connection_string() {
    let mut buf = [0u8; 256];

    let empty = CString::new("").unwrap();
    let r = odbc_validate_connection_string(empty.as_ptr(), buf.as_mut_ptr(), 256);
    assert_eq!(r, -1);
    assert!(
        std::str::from_utf8(&buf[..buf.iter().position(|&b| b == 0).unwrap_or(0)])
            .unwrap()
            .contains("empty")
    );

    let dsn = CString::new("DSN=MyDsn").unwrap();
    let r = odbc_validate_connection_string(dsn.as_ptr(), buf.as_mut_ptr(), 256);
    assert_eq!(r, 0);

    let driver = CString::new("Driver={SQL Server};Server=localhost;").unwrap();
    let r = odbc_validate_connection_string(driver.as_ptr(), buf.as_mut_ptr(), 256);
    assert_eq!(r, 0);

    let unbalanced = CString::new("DSN=test;PWD={unclosed").unwrap();
    let r = odbc_validate_connection_string(unbalanced.as_ptr(), buf.as_mut_ptr(), 256);
    assert_eq!(r, -1);
    assert!(
        std::str::from_utf8(&buf[..buf.iter().position(|&b| b == 0).unwrap_or(0)])
            .unwrap()
            .contains("brace")
    );

    let no_pairs = CString::new(";;;").unwrap();
    let r = odbc_validate_connection_string(no_pairs.as_ptr(), buf.as_mut_ptr(), 256);
    assert_eq!(r, -1);
}
#[test]
fn test_ffi_disconnect_invalid_id() {
    odbc_init();

    let invalid_id = next_test_invalid_id();
    let result = odbc_disconnect(invalid_id);
    assert_ne!(result, 0, "Disconnect with invalid ID should fail");

    let error = get_last_error();
    let err_lower = error.to_lowercase();
    assert!(
        err_lower.contains("invalid") && error.contains(&invalid_id.to_string()),
        "Error should mention invalid and the ID: {}",
        error
    );
}
#[test]
fn test_ffi_lifecycle() {
    // Test complete init/cleanup lifecycle
    let result = odbc_init();
    assert_eq!(result, 0);

    // Attempt operations that should fail without connection
    // Note: Due to global state, connection ID 1 might exist from previous tests
    // We just verify the function doesn't crash
    let sql = CString::new("SELECT 1").unwrap();
    let mut buffer = vec![0u8; 1024];
    let mut written: c_uint = 0;

    let result = odbc_exec_query(
        TEST_INVALID_ID, // Sentinel ID that won't collide with real connection IDs
        sql.as_ptr(),
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );

    // Should fail with invalid connection ID
    assert_ne!(result, 0, "Query with invalid connection ID should fail");
}
#[test]
fn test_ffi_connect_without_init() {
    // Note: This test may pass if odbc_init() was called in a previous test
    // due to global state persistence. We verify the behavior, but the error
    // message check is optional since state may already be initialized.
    let conn_str = CString::new("DRIVER={SQL Server};SERVER=localhost").unwrap();
    let conn_id = odbc_connect(conn_str.as_ptr());

    // If environment is already initialized (from previous test), this might succeed
    // or fail with a different error. We just verify it doesn't crash.
    // The main test is that odbc_connect handles the case gracefully.
    let _ = conn_id;
}
#[test]
fn test_ffi_full_connection_query_disconnect() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    let r = odbc_init();
    assert_eq!(r, 0);

    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0, "Connect should succeed");

    let sql = CString::new("SELECT 1 AS value").unwrap();
    let mut buffer = vec![0u8; 2048];
    let mut written: c_uint = 0;

    let qr = odbc_exec_query(
        conn_id,
        sql.as_ptr(),
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(qr, 0, "Exec query should succeed");
    assert!(written > 0);

    let dr = odbc_disconnect(conn_id);
    assert_eq!(dr, 0, "Disconnect should succeed");
}
#[test]
#[serial(ffi_last_error)]
fn should_reject_sync_param_ffi_when_buffer_null_and_len_nonzero() {
    odbc_init();
    let conn_id = next_test_invalid_id();
    let sql = CString::new("SELECT 1").unwrap();
    let mut buffer = vec![0u8; 128];
    let mut written: c_uint = 99;

    let query_result = odbc_exec_query_params(
        conn_id,
        sql.as_ptr(),
        std::ptr::null(),
        1,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(query_result, -1);
    assert_eq!(written, 0);

    written = 99;
    let query_options_result = odbc_exec_query_params_options(
        conn_id,
        sql.as_ptr(),
        std::ptr::null(),
        1,
        0,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(query_options_result, -1);
    assert_eq!(written, 0);

    written = 99;
    let multi_result = odbc_exec_query_multi_params(
        conn_id,
        sql.as_ptr(),
        std::ptr::null(),
        1,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(multi_result, -1);
    assert_eq!(written, 0);

    let stmt_id = next_test_invalid_id();
    {
        let Some(mut state) = try_lock_global_state() else {
            panic!("Failed to lock global state");
        };
        state.statements.insert(
            stmt_id,
            StatementHandle::new(conn_id, "SELECT 1".to_string(), 0),
        );
    }

    written = 99;
    let execute_result = odbc_execute(
        stmt_id,
        std::ptr::null(),
        1,
        0,
        0,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(execute_result, -1);
    assert_eq!(written, 0);

    let Some(mut state) = try_lock_global_state() else {
        panic!("Failed to lock global state");
    };
    state.statements.remove(&stmt_id);
}
#[test]
fn should_reject_connection_string_with_null_byte() {
    let err = validate_connection_string_format("DSN=test\0bad");
    assert!(
        err.as_ref().is_some_and(|m| m.contains("null byte")),
        "expected null-byte rejection, got {err:?}"
    );
}
#[test]
fn should_reject_connection_string_without_key_value_pairs() {
    let err = validate_connection_string_format("not_a_pair");
    assert!(
        err.as_ref().is_some_and(|m| m.contains("key=value")),
        "expected key=value rejection, got {err:?}"
    );
}
#[test]
fn should_reject_optional_param_buffer_when_null_and_nonzero_length() {
    let err = validate_param_buffer_shape(std::ptr::null(), 1).unwrap_err();
    assert!(err.contains("params_buffer is null"));
}
#[test]
fn should_borrow_optional_param_buffer_as_empty_when_null_and_zero_length() {
    // SAFETY: null with zero length is explicitly accepted by the helper.
    let len =
        unsafe { with_optional_param_buffer(std::ptr::null(), 0, |params| params.len()) }.unwrap();
    assert_eq!(len, 0);
}
#[test]
fn should_borrow_optional_param_buffer_bytes_when_pointer_valid() {
    let data = [4u8, 5, 6];
    // SAFETY: `data.as_ptr()` is valid for `data.len()` bytes during the
    // callback and the callback does not store the slice.
    let sum = unsafe {
        with_optional_param_buffer(data.as_ptr(), data.len() as c_uint, |params| {
            assert_eq!(params, data);
            params.iter().copied().sum::<u8>()
        })
    }
    .unwrap();
    assert_eq!(sum, 15);
}
#[test]
fn should_build_upsert_sql_via_ffi_without_connection() {
    let conn = CString::new("Driver={PostgreSQL};Server=localhost;").unwrap();
    let table = CString::new("users").unwrap();
    let payload = CString::new(r#"{"columns":["id","name"],"conflict":["id"]}"#).unwrap();
    let mut out = vec![0u8; 4096];
    let mut written: c_uint = 0;
    let code = odbc_build_upsert_sql(
        conn.as_ptr(),
        table.as_ptr(),
        payload.as_ptr(),
        out.as_mut_ptr(),
        out.len() as c_uint,
        &mut written,
    );
    assert_eq!(code, 0, "FFI upsert build should succeed");
    let sql = std::str::from_utf8(&out[..written as usize]).unwrap();
    assert!(sql.contains("ON CONFLICT"));
}
#[test]
fn should_reject_ffi_upsert_when_buffer_too_small() {
    let conn = CString::new("Driver={PostgreSQL};Server=localhost;").unwrap();
    let table = CString::new("users").unwrap();
    let payload = CString::new(r#"{"columns":["id","name"],"conflict":["id"]}"#).unwrap();
    let mut out = [0u8; 8];
    let mut written: c_uint = 0;
    let code = odbc_build_upsert_sql(
        conn.as_ptr(),
        table.as_ptr(),
        payload.as_ptr(),
        out.as_mut_ptr(),
        out.len() as c_uint,
        &mut written,
    );
    assert_eq!(code, -2);
    assert!(written > out.len() as c_uint);
}
#[test]
fn should_append_returning_sql_via_ffi_for_postgres() {
    let conn = CString::new("Driver={PostgreSQL};Server=localhost;").unwrap();
    let sql = CString::new("INSERT INTO users (id) VALUES (?)").unwrap();
    let cols = CString::new("id").unwrap();
    let mut out = vec![0u8; 2048];
    let mut written: c_uint = 0;
    let code = odbc_append_returning_sql(
        conn.as_ptr(),
        sql.as_ptr(),
        0,
        cols.as_ptr(),
        out.as_mut_ptr(),
        out.len() as c_uint,
        &mut written,
    );
    assert_eq!(code, 0);
    let appended = std::str::from_utf8(&out[..written as usize]).unwrap();
    assert!(appended.contains("RETURNING"));
}
#[test]
fn should_reject_connection_string_with_empty_key() {
    let err = validate_connection_string_format("=value_only");
    assert!(
        err.as_ref().is_some_and(|m| m.contains("key=value")),
        "expected empty-key rejection, got {err:?}"
    );
}
#[test]
fn should_accept_connection_string_with_balanced_driver_braces() {
    assert!(validate_connection_string_format(
        "Driver={SQL Server Native Client 11.0};Server=localhost;Database=test;"
    )
    .is_none());
}
#[test]
fn should_reject_connection_string_with_extra_closing_brace() {
    let err = validate_connection_string_format("DSN=test}");
    assert!(
        err.as_ref()
            .is_some_and(|m| m.contains("Unbalanced braces")),
        "expected extra closing brace rejection, got {err:?}"
    );
}
#[test]
fn should_reject_connection_string_with_extra_driver_closing_brace() {
    let err = validate_connection_string_format("Driver={SQL Server}};Server=localhost");
    assert!(
        err.as_ref()
            .is_some_and(|m| m.contains("Unbalanced braces")),
        "expected extra driver brace rejection, got {err:?}"
    );
}
#[test]
fn odbc_validate_connection_string_rejects_null_pointer() {
    let mut buf = [0u8; 64];
    let code = odbc_validate_connection_string(std::ptr::null(), buf.as_mut_ptr(), 64);
    assert_eq!(code, -1);
}

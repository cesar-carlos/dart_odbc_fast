//! Prepared-statement and cancel FFI tests.

use crate::ffi::global::*;
use crate::ffi::prelude::StatementHandle;
use crate::ffi::state;
use crate::ffi::*;
use serial_test::serial;
use std::ffi::CString;
use std::os::raw::c_uint;

use super::super::support::{
    ffi_test_dsn, ffi_test_dsn_is_sql_server, get_last_error, TEST_INVALID_ID,
};

#[test]
fn test_ffi_prepare_null_sql() {
    odbc_init();
    let stmt_id = odbc_prepare(1, std::ptr::null(), 0);
    assert_eq!(stmt_id, 0, "Prepare with null SQL should return 0");
}

#[test]
fn test_ffi_prepare_invalid_conn() {
    odbc_init();
    let sql = CString::new("SELECT 1").unwrap();
    let stmt_id = odbc_prepare(TEST_INVALID_ID, sql.as_ptr(), 0);
    assert_eq!(stmt_id, 0, "Prepare with invalid conn_id should return 0");
    let err = get_last_error();
    assert!(
        err.contains("Invalid connection") || err.contains(&TEST_INVALID_ID.to_string()),
        "Error should mention invalid connection: {}",
        err
    );
}

#[test]
#[serial(ffi_last_error)]
fn test_ffi_close_statement_invalid() {
    odbc_init();
    let r = odbc_close_statement(TEST_INVALID_ID);
    assert_ne!(r, 0, "Close invalid statement should fail");
    let err = get_last_error();
    assert!(
        err.contains("Invalid statement") || err.contains(&TEST_INVALID_ID.to_string()),
        "Error should mention invalid statement: {}",
        err
    );
}

#[test]
fn test_ffi_clear_all_statements() {
    odbc_init();

    state::insert_statement(1001, StatementHandle::new(1, "SELECT 1".to_string(), 0));
    state::insert_statement(1002, StatementHandle::new(1, "SELECT 2".to_string(), 0));
    assert_eq!(
        state::statement_count_for_test(),
        2,
        "Test setup should create statements"
    );

    let r = odbc_clear_all_statements();
    assert_eq!(r, 0, "Clear all statements should succeed");
    assert!(
        state::statements_empty_for_test(),
        "All statements should be removed"
    );
}

#[test]
#[serial(ffi_last_error)]
fn test_ffi_cancel_invalid_stmt() {
    odbc_init();
    let r = odbc_cancel(TEST_INVALID_ID);
    assert_ne!(r, 0, "Cancel invalid statement should fail");
    let err = get_last_error();
    assert!(
        err.contains("Invalid statement") || err.contains(&TEST_INVALID_ID.to_string()),
        "Error should mention invalid statement: {}",
        err
    );
}

#[test]
fn test_ffi_cancel_supported_path_returns_structured_unsupported_feature() {
    odbc_init();

    let stmt_id = 1100;
    state::insert_statement(stmt_id, StatementHandle::new(1, "SELECT 1".to_string(), 0));

    let r = odbc_cancel(stmt_id);
    assert_ne!(r, 0, "Cancel should fail because feature is unsupported");

    let mut buffer = vec![0u8; 1024];
    let mut written: c_uint = 0;
    let result =
        odbc_get_structured_error(buffer.as_mut_ptr(), buffer.len() as c_uint, &mut written);
    assert_eq!(
        result, 0,
        "Structured error should be available for unsupported cancel"
    );
    assert!(written > 0, "Structured error payload should be non-empty");

    let structured =
        crate::error::StructuredError::deserialize(&buffer[..written as usize]).unwrap();
    assert_eq!(structured.sqlstate, *b"0A000");
    assert_eq!(structured.native_code, CANCEL_UNSUPPORTED_NATIVE_CODE);
    assert!(
        structured.message.contains("Unsupported feature")
            && structured.message.contains("Statement cancellation"),
        "Unexpected structured error message: {}",
        structured.message
    );

    let _ = state::remove_statement(stmt_id);
}

#[test]
fn test_ffi_prepare_execute_close() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let sql = CString::new("SELECT 1 AS x").unwrap();
    let stmt_id = odbc_prepare(conn_id, sql.as_ptr(), 0);
    assert!(stmt_id > 0, "Prepare should succeed");

    let mut buffer = vec![0u8; 2048];
    let mut written: c_uint = 0;
    let result = odbc_execute(
        stmt_id,
        std::ptr::null(),
        0,
        0,
        0,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(result, 0, "Execute should succeed");
    assert!(written > 0);

    let close_r = odbc_close_statement(stmt_id);
    assert_eq!(close_r, 0, "Close statement should succeed");

    let _ = odbc_disconnect(conn_id);
}

#[test]
fn test_ffi_prepare_execute_with_timeout() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let sql = CString::new("SELECT 1 AS x").unwrap();
    let stmt_id = odbc_prepare(conn_id, sql.as_ptr(), 5000);
    assert!(stmt_id > 0, "Prepare with timeout should succeed");

    let mut buffer = vec![0u8; 2048];
    let mut written: c_uint = 0;
    let result = odbc_execute(
        stmt_id,
        std::ptr::null(),
        0,
        0,
        0,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(result, 0, "Execute with timeout should succeed");
    assert!(written > 0);

    let _ = odbc_close_statement(stmt_id);
    let _ = odbc_disconnect(conn_id);
}

#[test]
fn test_ffi_execute_retry_after_buffer_too_small_does_not_reexecute_side_effect_sql() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };
    if !ffi_test_dsn_is_sql_server(&dsn) {
        eprintln!("⚠️  Skipping: SQL Server-only T-SQL (IF OBJECT_ID / INSERT OUTPUT)");
        return;
    }

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).expect("valid DSN");
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let table = format!("ffi_exec_retry_guard_{}", std::process::id());
    let setup_sql = CString::new(format!(
        "IF OBJECT_ID('{table}', 'U') IS NOT NULL DROP TABLE {table}; \
         CREATE TABLE {table} (id INT PRIMARY KEY)"
    ))
    .unwrap();
    let mut setup_buf = vec![0u8; 1024];
    let mut setup_written: c_uint = 0;
    let create_result = odbc_exec_query(
        conn_id,
        setup_sql.as_ptr(),
        setup_buf.as_mut_ptr(),
        setup_buf.len() as c_uint,
        &mut setup_written,
    );
    assert_eq!(create_result, 0, "Table setup should succeed");

    let sql = CString::new(format!(
        "INSERT INTO {table} (id) \
         OUTPUT REPLICATE('X', 6000) AS payload \
         VALUES (42)"
    ))
    .unwrap();
    let stmt_id = odbc_prepare(conn_id, sql.as_ptr(), 0);
    assert!(stmt_id > 0, "Prepare should succeed");

    let mut small_buffer = vec![0u8; 512];
    let mut written: c_uint = 0;
    let first = odbc_execute(
        stmt_id,
        std::ptr::null(),
        0,
        0,
        0,
        small_buffer.as_mut_ptr(),
        small_buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(first, -2, "First execute should report buffer too small");
    assert!(
        written > small_buffer.len() as c_uint,
        "Should report required size on -2"
    );

    let mut larger_buffer = vec![0u8; 16 * 1024];
    let second = odbc_execute(
        stmt_id,
        std::ptr::null(),
        0,
        0,
        0,
        larger_buffer.as_mut_ptr(),
        larger_buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(
        second, 0,
        "Retry must succeed by delivering pending payload without re-executing SQL",
    );
    assert!(written > 0);

    let _ = odbc_close_statement(stmt_id);

    let drop_sql = CString::new(format!("DROP TABLE IF EXISTS {table}")).unwrap();
    let mut db = vec![0u8; 1024];
    let mut dw: c_uint = 0;
    let _ = odbc_exec_query(
        conn_id,
        drop_sql.as_ptr(),
        db.as_mut_ptr(),
        db.len() as c_uint,
        &mut dw,
    );

    let _ = odbc_disconnect(conn_id);
}

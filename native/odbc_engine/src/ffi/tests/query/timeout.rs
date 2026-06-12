//! Execute timeout override FFI tests.

use crate::ffi::*;
use std::ffi::CString;
use std::os::raw::c_uint;

use super::super::support::{ffi_test_dsn, ffi_test_dsn_is_sql_server};

#[test]
fn test_ffi_timeout_override_short_fails() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN + ENABLE_E2E_TESTS not set");
        return;
    };
    if !ffi_test_dsn_is_sql_server(&dsn) {
        eprintln!("⚠️  Skipping: SQL Server-only T-SQL (WAITFOR DELAY)");
        return;
    }

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let sql = CString::new("WAITFOR DELAY '00:00:03'").unwrap();
    let stmt_id = odbc_prepare(conn_id, sql.as_ptr(), 30000);
    assert!(stmt_id > 0);

    let mut buffer = vec![0u8; 2048];
    let mut written: c_uint = 0;
    let result = odbc_execute(
        stmt_id,
        std::ptr::null(),
        0,
        1000,
        0,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_ne!(
        result, 0,
        "Execute with 1s timeout should fail for 3s query"
    );

    let _ = odbc_close_statement(stmt_id);
    let _ = odbc_disconnect(conn_id);
}

#[test]
fn test_ffi_timeout_override_sufficient_succeeds() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN + ENABLE_E2E_TESTS not set");
        return;
    };
    if !ffi_test_dsn_is_sql_server(&dsn) {
        eprintln!("⚠️  Skipping: SQL Server-only T-SQL (WAITFOR DELAY)");
        return;
    }

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let sql = CString::new("WAITFOR DELAY '00:00:01'").unwrap();
    let stmt_id = odbc_prepare(conn_id, sql.as_ptr(), 0);
    assert!(stmt_id > 0);

    let mut buffer = vec![0u8; 2048];
    let mut written: c_uint = 0;
    let result = odbc_execute(
        stmt_id,
        std::ptr::null(),
        0,
        5000,
        0,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(
        result, 0,
        "Execute with 5s timeout should succeed for 1s query"
    );

    let _ = odbc_close_statement(stmt_id);
    let _ = odbc_disconnect(conn_id);
}

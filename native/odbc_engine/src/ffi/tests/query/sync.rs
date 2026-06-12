//! Sync `odbc_exec_query` validation and metrics tests.

use crate::ffi::global::*;
use crate::ffi::*;
use std::ffi::CString;
use std::os::raw::c_uint;

use super::super::support::{get_last_error, TEST_INVALID_ID};

#[test]
fn test_ffi_exec_query_null_sql() {
    odbc_init();

    let mut buffer = vec![0u8; 1024];
    let mut written: c_uint = 0;

    let result = odbc_exec_query(
        1,
        std::ptr::null(),
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );

    assert_eq!(result, -1, "Null SQL should return -1");
}

#[test]
fn test_ffi_exec_query_invalid_conn_id() {
    odbc_init();

    let sql = CString::new("SELECT 1").unwrap();
    let mut buffer = vec![0u8; 1024];
    let mut written: c_uint = 0;

    let result = odbc_exec_query(
        TEST_INVALID_ID,
        sql.as_ptr(),
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );

    assert_eq!(result, -1, "Invalid connection ID should return -1");

    let error = get_last_error();
    assert!(
        error.contains("Invalid connection ID")
            || error.contains("Invalid pool ID")
            || error.contains(&TEST_INVALID_ID.to_string()),
        "Error should mention invalid ID: {}",
        error
    );
}

#[test]
fn test_ffi_exec_query_null_buffer() {
    odbc_init();

    let sql = CString::new("SELECT 1").unwrap();
    let mut written: c_uint = 0;

    let result = odbc_exec_query(1, sql.as_ptr(), std::ptr::null_mut(), 1024, &mut written);

    assert_eq!(result, -1, "Null buffer should return -1");
}

#[test]
fn test_ffi_exec_query_buffer_too_small() {
    odbc_init();

    let sql = CString::new("SELECT 1").unwrap();
    let mut buffer = vec![0u8; 1];
    let mut written: c_uint = 0;

    let result = odbc_exec_query(
        TEST_INVALID_ID,
        sql.as_ptr(),
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );

    assert_eq!(result, -1, "Should fail (invalid conn ID)");
}

#[test]
fn test_ffi_exec_query_null_out_written() {
    odbc_init();

    let sql = CString::new("SELECT 1").unwrap();
    let mut buffer = vec![0u8; 1024];

    let result = odbc_exec_query(
        1,
        sql.as_ptr(),
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        std::ptr::null_mut(),
    );

    assert_eq!(result, -1, "Null out_written should return -1");
}

#[test]
fn test_ffi_exec_query_null_out_buffer() {
    odbc_init();

    let sql = CString::new("SELECT 1").unwrap();
    let mut written: c_uint = 0;

    let result = odbc_exec_query(1, sql.as_ptr(), std::ptr::null_mut(), 1024, &mut written);

    assert_eq!(result, -1, "Null output buffer should return -1");
}

#[test]
fn test_odbc_get_metrics_success() {
    odbc_init();

    let mut buffer = vec![0u8; 64];
    let mut written: c_uint = 0;

    let result = odbc_get_metrics(buffer.as_mut_ptr(), buffer.len() as c_uint, &mut written);

    assert_eq!(result, 0, "odbc_get_metrics should succeed");
    assert_eq!(written, 40, "Should write 40 bytes");
}

#[test]
fn test_odbc_get_metrics_buffer_too_small() {
    odbc_init();

    let mut buffer = vec![0u8; 32];
    let mut written: c_uint = 0;

    let result = odbc_get_metrics(buffer.as_mut_ptr(), buffer.len() as c_uint, &mut written);

    assert_eq!(result, -2, "Buffer too small should return -2");
    assert_eq!(written, 40, "Should report required metrics buffer size");
}

#[test]
fn test_odbc_get_metrics_null_buffer() {
    odbc_init();

    let mut written: c_uint = 0;

    let result = odbc_get_metrics(std::ptr::null_mut(), 64, &mut written);

    assert_eq!(result, -1, "Null buffer should return -1");
}

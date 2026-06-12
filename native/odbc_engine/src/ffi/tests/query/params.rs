//! Parameterized sync query FFI tests.

use crate::ffi::*;
use crate::protocol::{serialize_params, ParamValue};
use std::ffi::CString;
use std::os::raw::c_uint;

use super::super::support::{ffi_test_dsn, get_last_error};

#[test]
fn test_ffi_exec_query_params_null_buffer() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let sql = CString::new("SELECT 1 AS value").unwrap();
    let mut buffer = vec![0u8; 2048];
    let mut written: c_uint = 0;

    let result = odbc_exec_query_params(
        conn_id,
        sql.as_ptr(),
        std::ptr::null(),
        0,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(
        result, 0,
        "odbc_exec_query_params with null params buffer should succeed"
    );
    assert!(written > 0);

    let _ = odbc_disconnect(conn_id);
}

#[test]
fn test_ffi_exec_query_params_success() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let params = vec![ParamValue::Integer(42)];
    let params_bytes = serialize_params(&params);

    let sql = CString::new("SELECT ? AS value").unwrap();
    let mut buffer = vec![0u8; 2048];
    let mut written: c_uint = 0;

    let result = odbc_exec_query_params(
        conn_id,
        sql.as_ptr(),
        params_bytes.as_ptr(),
        params_bytes.len() as c_uint,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(result, 0, "odbc_exec_query_params should succeed");
    assert!(written > 0);

    let _ = odbc_disconnect(conn_id);
}

#[test]
fn test_ffi_exec_query_params_options_row_major_success() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let params = vec![ParamValue::Integer(42)];
    let params_bytes = serialize_params(&params);

    let sql = CString::new("SELECT ? AS value").unwrap();
    let mut buffer = vec![0u8; 2048];
    let mut written: c_uint = 0;

    let result = odbc_exec_query_params_options(
        conn_id,
        sql.as_ptr(),
        params_bytes.as_ptr(),
        params_bytes.len() as c_uint,
        0,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(
        result, 0,
        "odbc_exec_query_params_options row-major should succeed"
    );
    assert!(written > 0);

    let invalid = odbc_exec_query_params_options(
        conn_id,
        sql.as_ptr(),
        params_bytes.as_ptr(),
        params_bytes.len() as c_uint,
        99,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(invalid, -1, "invalid result encoding should fail");

    let _ = odbc_disconnect(conn_id);
}

#[test]
fn test_ffi_exec_query_params_invalid_params() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let invalid_params = [0xffu8, 0, 0, 0, 0];
    let sql = CString::new("SELECT 1").unwrap();
    let mut buffer = vec![0u8; 2048];
    let mut written: c_uint = 0;

    let result = odbc_exec_query_params(
        conn_id,
        sql.as_ptr(),
        invalid_params.as_ptr(),
        invalid_params.len() as c_uint,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(result, -1, "Invalid params buffer should return -1");

    let error = get_last_error();
    assert!(
        error.contains("Invalid params") || error.contains("Unknown ParamValue tag"),
        "Error should mention invalid params: {}",
        error
    );

    let _ = odbc_disconnect(conn_id);
}

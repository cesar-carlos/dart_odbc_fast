//! FFI `core::catalog` tests.

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
fn should_build_catalog_cache_key_with_stable_format() {
    assert_eq!(build_catalog_cache_key(42, "dbo.Users"), "42:dbo.Users");
    assert_eq!(build_catalog_cache_key(0, ""), "0:");
}
#[test]
#[serial]
fn should_return_cached_catalog_columns_without_connection_lookup() {
    odbc_init();
    odbc_metadata_cache_enable(100, 300);

    let conn_id = next_test_invalid_id();
    let table = CString::new("dbo.Users").unwrap();
    let payload = br#"[{"name":"id","type":4}]"#;
    let cache_key = build_catalog_cache_key(conn_id, "dbo.Users");
    {
        let state = try_lock_global_state().expect("global state should lock");
        state.metadata_cache.cache_payload(&cache_key, payload);
    }

    let mut buffer = vec![0u8; payload.len()];
    let mut written: c_uint = 0;
    let result = odbc_catalog_columns(
        conn_id,
        table.as_ptr(),
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );

    assert_eq!(result, 0, "cached catalog payload should be returned");
    assert_eq!(written as usize, payload.len());
    assert_eq!(&buffer[..written as usize], payload);
}
#[test]
#[serial]
fn should_report_cached_catalog_columns_buffer_too_small() {
    odbc_init();
    odbc_metadata_cache_enable(100, 300);

    let conn_id = next_test_invalid_id();
    let table = CString::new("dbo.Users").unwrap();
    let payload = br#"[{"name":"id","type":4}]"#;
    let cache_key = build_catalog_cache_key(conn_id, "dbo.Users");
    {
        let state = try_lock_global_state().expect("global state should lock");
        state.metadata_cache.cache_payload(&cache_key, payload);
    }

    let mut buffer = vec![0u8; 4];
    let mut written: c_uint = 0;
    let result = odbc_catalog_columns(
        conn_id,
        table.as_ptr(),
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );

    assert_eq!(result, -2, "small buffer should keep FFI contract");
    assert_eq!(written as usize, payload.len());
}
#[test]
fn test_ffi_catalog_tables_invalid_conn() {
    odbc_init();

    let mut buf = vec![0u8; 4096];
    let mut written: c_uint = 0;
    let r = odbc_catalog_tables(
        TEST_INVALID_ID,
        std::ptr::null(),
        std::ptr::null(),
        buf.as_mut_ptr(),
        buf.len() as c_uint,
        &mut written,
    );
    assert_eq!(r, -1, "Invalid conn_id should return -1");
}
#[test]
fn test_ffi_catalog_tables_null_buffer() {
    odbc_init();

    let mut written: c_uint = 0;
    let r = odbc_catalog_tables(
        1,
        std::ptr::null(),
        std::ptr::null(),
        std::ptr::null_mut(),
        4096,
        &mut written,
    );
    assert_eq!(r, -1, "Null buffer should return -1");
}
#[test]
fn test_ffi_catalog_columns_null_table() {
    odbc_init();

    let mut buf = vec![0u8; 4096];
    let mut written: c_uint = 0;
    let r = odbc_catalog_columns(
        1,
        std::ptr::null(),
        buf.as_mut_ptr(),
        buf.len() as c_uint,
        &mut written,
    );
    assert_eq!(r, -1, "Null table should return -1");
}
#[test]
fn test_ffi_catalog_columns_invalid_conn() {
    odbc_init();

    let tbl = CString::new("TABLES").unwrap();
    let mut buf = vec![0u8; 4096];
    let mut written: c_uint = 0;
    let r = odbc_catalog_columns(
        TEST_INVALID_ID,
        tbl.as_ptr(),
        buf.as_mut_ptr(),
        buf.len() as c_uint,
        &mut written,
    );
    assert_eq!(r, -1, "Invalid conn_id should return -1");
}
#[test]
fn test_ffi_catalog_type_info_invalid_conn() {
    odbc_init();

    let mut buf = vec![0u8; 4096];
    let mut written: c_uint = 0;
    let r = odbc_catalog_type_info(
        TEST_INVALID_ID,
        buf.as_mut_ptr(),
        buf.len() as c_uint,
        &mut written,
    );
    assert_eq!(r, -1, "Invalid conn_id should return -1");
}

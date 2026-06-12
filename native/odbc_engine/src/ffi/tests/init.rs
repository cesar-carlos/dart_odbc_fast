//! FFI `core::init` tests.

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
fn odbc_get_version_uses_version_modules() {
    let mut buffer = vec![0u8; 128];
    let mut written: c_uint = 0;

    let code = odbc_get_version(buffer.as_mut_ptr(), buffer.len() as c_uint, &mut written);

    assert_eq!(code, 0);
    let text = std::str::from_utf8(&buffer[..written as usize]).unwrap();
    let json: Value = serde_json::from_str(text).unwrap();
    let expected_api = ApiVersion::current().to_string();
    let expected_abi = AbiVersion::current().to_string();
    assert_eq!(json["api"].as_str(), Some(expected_api.as_str()));
    assert_eq!(json["abi"].as_str(), Some(expected_abi.as_str()));
}
#[test]
fn test_simulated_long_call_can_reacquire_global_state_after_lookup() {
    odbc_init();
    {
        let Some(_lookup_phase) = try_lock_global_state() else {
            panic!("Failed to lock global state");
        };
    }

    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let reacquired = try_lock_global_state().is_some();
        tx.send(reacquired).expect("send lock result");
    });

    assert_eq!(
        rx.recv_timeout(Duration::from_millis(250)),
        Ok(true),
        "simulated ODBC execution must not keep GLOBAL_STATE locked"
    );
}
#[test]
fn test_ffi_metadata_cache_enable() {
    odbc_init();

    let result = odbc_metadata_cache_enable(200, 600);
    assert_eq!(result, 0, "Metadata cache enable should succeed");
}
#[test]
fn test_ffi_metadata_cache_enable_zero_values() {
    odbc_init();

    // Zero values should be clamped to minimum (1)
    let result = odbc_metadata_cache_enable(0, 0);
    assert_eq!(result, 0, "Metadata cache enable with zeros should succeed");
}
#[test]
fn test_ffi_metadata_cache_stats() {
    odbc_init();
    // Note: Using unique values to verify the enable call worked
    let expected_max_size = 150;
    let expected_ttl = 450;
    odbc_metadata_cache_enable(expected_max_size, expected_ttl);

    let mut buffer = vec![0u8; 512];
    let mut written: c_uint = 0;
    let result =
        odbc_metadata_cache_stats(buffer.as_mut_ptr(), buffer.len() as c_uint, &mut written);
    assert_eq!(result, 0, "Metadata cache stats should succeed");
    assert!(written > 0, "Stats payload should not be empty");

    let payload = &buffer[..written as usize];
    let parsed: Value = serde_json::from_slice(payload).expect("Valid stats JSON payload");

    // Verify JSON structure contains all expected fields
    let max_size = parsed.get("max_size").and_then(Value::as_u64);
    let ttl_secs = parsed.get("ttl_secs").and_then(Value::as_u64);
    assert!(max_size.is_some(), "Stats should contain max_size");
    assert!(ttl_secs.is_some(), "Stats should contain ttl_secs");
    assert!(
        parsed
            .get("schema_entries")
            .and_then(Value::as_u64)
            .is_some(),
        "Stats should contain schema_entries"
    );
    assert!(
        parsed
            .get("payload_entries")
            .and_then(Value::as_u64)
            .is_some(),
        "Stats should contain payload_entries"
    );

    // Verify values are reasonable (positive integers)
    assert!(max_size.unwrap() > 0, "max_size should be positive");
    assert!(ttl_secs.unwrap() > 0, "ttl_secs should be positive");
}
#[test]
fn test_ffi_metadata_cache_stats_null_buffer() {
    odbc_init();

    let mut written: c_uint = 0;
    let result = odbc_metadata_cache_stats(std::ptr::null_mut(), 512, &mut written);
    assert_eq!(result, -1, "Null buffer should return -1");
}
#[test]
fn test_ffi_metadata_cache_stats_null_out_written() {
    odbc_init();

    let mut buffer = vec![0u8; 512];
    let result = odbc_metadata_cache_stats(
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        std::ptr::null_mut(),
    );
    assert_eq!(result, -1, "Null out_written should return -1");
}
#[test]
fn test_ffi_metadata_cache_stats_buffer_too_small() {
    odbc_init();

    let mut buffer = vec![0u8; 1]; // Too small
    let mut written: c_uint = 0;
    let result =
        odbc_metadata_cache_stats(buffer.as_mut_ptr(), buffer.len() as c_uint, &mut written);
    assert_eq!(result, -2, "Too small buffer should return -2");
    assert!(
        written > buffer.len() as c_uint,
        "written should report required size on buffer-too-small"
    );
}
#[test]
fn test_ffi_metadata_cache_clear() {
    odbc_init();
    odbc_metadata_cache_enable(50, 120);

    let result = odbc_metadata_cache_clear();
    assert_eq!(result, 0, "Metadata cache clear should succeed");
}
#[test]
fn test_ffi_get_driver_capabilities() {
    let conn_str = CString::new("Driver={SQL Server};Server=localhost;Database=test;").unwrap();
    let mut buffer = vec![0u8; 512];
    let mut written: c_uint = 0;
    let result = odbc_get_driver_capabilities(
        conn_str.as_ptr(),
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(result, 0, "Driver capabilities should succeed");
    assert!(written > 0, "Payload should not be empty");

    let payload = &buffer[..written as usize];
    let parsed: Value = serde_json::from_slice(payload).expect("Valid capabilities JSON");
    assert_eq!(
        parsed.get("driver_name").and_then(Value::as_str),
        Some("SQL Server"),
        "Should detect SQL Server"
    );
    assert!(
        parsed
            .get("supports_prepared_statements")
            .and_then(Value::as_bool)
            == Some(true),
        "Should support prepared statements"
    );
}
#[test]
#[serial]
fn test_ffi_get_driver_capabilities_buffer_too_small() {
    let conn_str = CString::new("Driver={SQL Server};Server=localhost;Database=test;").unwrap();
    let mut buffer = vec![0u8; 8];
    let mut written: c_uint = 123;
    let result = odbc_get_driver_capabilities(
        conn_str.as_ptr(),
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(result, -2, "Too small buffer should return -2");
    assert!(
        written > buffer.len() as c_uint,
        "written should report required size on buffer-too-small"
    );
}
#[test]
fn test_ffi_get_driver_capabilities_null_conn_str() {
    let mut buffer = vec![0u8; 256];
    let mut written: c_uint = 0;
    let result = odbc_get_driver_capabilities(
        std::ptr::null(),
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(result, -1);
    assert_eq!(written, 0);
}
#[test]
fn test_ffi_set_log_level() {
    let result = odbc_set_log_level(0);
    assert_eq!(result, 0);
    assert_eq!(odbc_set_log_level(1), 0);
    assert_eq!(odbc_set_log_level(2), 0);
    assert_eq!(odbc_set_log_level(3), 0);
    assert_eq!(odbc_set_log_level(4), 0);
    assert_eq!(odbc_set_log_level(5), 0);
    assert_eq!(odbc_set_log_level(99), 0);
}
#[test]
fn test_ffi_init() {
    let result = odbc_init();
    assert_eq!(result, 0, "odbc_init should succeed");

    // Second init should also succeed (idempotent)
    let result = odbc_init();
    assert_eq!(result, 0, "odbc_init should be idempotent");
}
#[test]
fn should_parse_optional_c_string_pointers() {
    assert_eq!(ptr_to_opt_str(std::ptr::null()), None);
    let empty = CString::new("").unwrap();
    assert_eq!(ptr_to_opt_str(empty.as_ptr()), None);
    let spaces = CString::new("   ").unwrap();
    assert_eq!(ptr_to_opt_str(spaces.as_ptr()), None);
    let val = CString::new("  myschema ").unwrap();
    assert_eq!(ptr_to_opt_str(val.as_ptr()), Some("myschema".to_string()));
}
#[test]
fn should_set_out_written_helpers() {
    let mut written: c_uint = 99;
    set_out_written_zero(&mut written);
    assert_eq!(written, 0);
    set_out_written_needed(&mut written, 512);
    assert_eq!(written, 512);
}
#[test]
fn should_read_env_usize_with_fallback() {
    let key = "ODBC_TEST_READ_ENV_USIZE_XYZ";
    std::env::remove_var(key);
    assert_eq!(read_env_usize(key, 42), 42);
    std::env::set_var(key, "100");
    assert_eq!(read_env_usize(key, 42), 100);
    std::env::remove_var(key);
}
#[test]
fn should_read_env_u64_with_fallback() {
    let key = "ODBC_TEST_READ_ENV_U64_XYZ";
    std::env::remove_var(key);
    assert_eq!(read_env_u64(key, 7), 7);
    std::env::set_var(key, "9001");
    assert_eq!(read_env_u64(key, 7), 9001);
    std::env::remove_var(key);
}

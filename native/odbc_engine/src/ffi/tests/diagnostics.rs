//! FFI `core::diagnostics` tests.

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
#[serial]
fn test_ffi_audit_enable_get_and_clear() {
    odbc_init();
    assert_eq!(odbc_audit_clear(), 0);
    assert_eq!(odbc_audit_enable(1), 0);

    let audit = state::ffi_audit_logger();
    assert!(audit.is_enabled());
    audit.log_query(42, "SELECT 1");
    audit.log_error(Some(42), "boom");

    let mut buffer = vec![0u8; 4096];
    let mut written: c_uint = 0;
    let result =
        odbc_audit_get_events(buffer.as_mut_ptr(), buffer.len() as c_uint, &mut written, 0);
    assert_eq!(result, 0, "Audit events should be returned");
    assert!(written > 0, "Audit payload should not be empty");

    let payload = &buffer[..written as usize];
    let parsed: Value = serde_json::from_slice(payload).expect("Valid JSON payload");
    let events = parsed.as_array().expect("Expected JSON array");
    assert!(!events.is_empty(), "Expected at least one audit event");
    let has_query_or_error = events.iter().any(|event| {
        event.get("event_type").and_then(Value::as_str) == Some("query")
            || event.get("event_type").and_then(Value::as_str) == Some("error")
    });
    assert!(
        has_query_or_error,
        "Expected query/error event in audit payload",
    );

    assert_eq!(odbc_audit_clear(), 0);
    assert_eq!(state::ffi_audit_logger().event_count(), 0);
}
#[test]
#[serial]
fn test_ffi_audit_get_events_buffer_too_small() {
    odbc_init();
    assert_eq!(odbc_audit_clear(), 0);
    assert_eq!(odbc_audit_enable(1), 0);
    state::ffi_audit_logger().log_query(7, "SELECT 7");

    let mut tiny_buffer = [0u8; 4];
    let mut written: c_uint = 123;
    let result = odbc_audit_get_events(
        tiny_buffer.as_mut_ptr(),
        tiny_buffer.len() as c_uint,
        &mut written,
        0,
    );

    assert_eq!(result, -2, "Tiny buffer should return -2");
    assert!(
        written > tiny_buffer.len() as c_uint,
        "written should report required size on buffer-too-small"
    );
}
#[test]
#[serial]
fn test_ffi_audit_get_status() {
    odbc_init();
    assert_eq!(odbc_audit_clear(), 0);
    assert_eq!(odbc_audit_enable(1), 0);

    let mut status_buffer = vec![0u8; 256];
    let mut written: c_uint = 0;
    let result = odbc_audit_get_status(
        status_buffer.as_mut_ptr(),
        status_buffer.len() as c_uint,
        &mut written,
    );
    assert_eq!(result, 0, "Audit status should be returned");
    assert!(written > 0, "Audit status payload should not be empty");

    let payload = &status_buffer[..written as usize];
    let parsed: Value = serde_json::from_slice(payload).expect("Valid status JSON payload");
    assert!(
        parsed.get("enabled").and_then(Value::as_bool).is_some(),
        "Status payload should contain enabled",
    );
    assert!(
        parsed.get("event_count").and_then(Value::as_u64).is_some(),
        "Status payload should contain event_count",
    );
}

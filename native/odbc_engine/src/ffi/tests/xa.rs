//! FFI `xa` tests.

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
fn should_read_xa_buffer_as_empty_when_null_and_zero_length() {
    assert_eq!(xa_read_buffer(std::ptr::null(), 0), Some(Vec::new()));
    assert_eq!(xa_read_buffer(std::ptr::null(), 1), None);
}

#[test]
fn should_copy_xa_buffer_bytes_when_pointer_valid() {
    let data = [1u8, 2, 3];
    assert_eq!(
        xa_read_buffer(data.as_ptr(), data.len() as c_uint),
        Some(vec![1, 2, 3])
    );
}

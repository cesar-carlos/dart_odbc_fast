//! FFI `bulk` tests.

#![allow(unused_imports)]

use crate::ffi::bulk::bulk_rows_inserted_for_ffi;
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
fn should_reject_bulk_row_count_above_u32_max() {
    let overflow = (c_uint::MAX as usize) + 1;
    let result = bulk_rows_inserted_for_ffi(overflow);
    assert!(result.is_err(), "row counts above u32::MAX must fail");
    assert_eq!(
        bulk_rows_inserted_for_ffi(c_uint::MAX as usize).unwrap(),
        c_uint::MAX
    );
}

#[test]
fn test_ffi_bulk_insert_null_buffer() {
    odbc_init();
    let mut rows: c_uint = 0;
    let r = odbc_bulk_insert_array(
        1,
        std::ptr::null(),
        std::ptr::null(),
        0,
        std::ptr::null(),
        100,
        0,
        &mut rows,
    );
    assert_eq!(r, -1, "Null data_buffer should return -1");
}

#[test]
fn test_ffi_bulk_insert_null_rows_inserted() {
    odbc_init();
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "a".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: 0,
        column_data: vec![],
    };
    let enc = serialize_bulk_insert_payload(&payload).unwrap();
    let r = odbc_bulk_insert_array(
        1,
        std::ptr::null(),
        std::ptr::null(),
        0,
        enc.as_ptr(),
        enc.len() as c_uint,
        0,
        std::ptr::null_mut(),
    );
    assert_eq!(r, -1, "Null rows_inserted should return -1");
}

#[test]
fn test_ffi_bulk_insert_zero_len() {
    odbc_init();
    let mut rows: c_uint = 0;
    let buf = [0u8; 8];
    let r = odbc_bulk_insert_array(
        1,
        std::ptr::null(),
        std::ptr::null(),
        0,
        buf.as_ptr(),
        0,
        0,
        &mut rows,
    );
    assert_eq!(r, -1, "Zero buffer_len should return -1");
}

#[test]
fn test_ffi_bulk_insert_invalid_conn() {
    odbc_init();
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "a".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: 2,
        column_data: vec![BulkColumnData::I32 {
            values: vec![1, 2],
            null_bitmap: None,
        }],
    };
    let enc = serialize_bulk_insert_payload(&payload).unwrap();
    let mut rows: c_uint = 0;
    let r = odbc_bulk_insert_array(
        TEST_INVALID_ID,
        std::ptr::null(),
        std::ptr::null(),
        0,
        enc.as_ptr(),
        enc.len() as c_uint,
        0,
        &mut rows,
    );
    assert_eq!(r, -1, "Invalid conn_id should return -1");
    let err = get_last_error();
    assert!(
        err.contains("Invalid connection")
            || err.contains("Invalid pool ID")
            || err.contains(&TEST_INVALID_ID.to_string())
            || err.contains("payload truncated")
            || err.contains("data_buffer")
            || err.contains("non-null")
            || err.contains("buffer_len"),
        "Error should mention invalid connection, payload, or buffer: {}",
        err
    );
}

#[test]
fn test_ffi_bulk_insert_array_accepts_v2_payload_before_connection_lookup() {
    odbc_init();
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "blob".to_string(),
            col_type: BulkColumnType::Binary,
            nullable: false,
            max_len: 8,
        }],
        row_count: 1,
        column_data: vec![BulkColumnData::Binary {
            rows: crate::protocol::bulk_rows_from_vecs(vec![vec![1, 0, 2]]),
            max_len: 8,
            null_bitmap: None,
        }],
    };
    let enc = serialize_bulk_insert_payload_v2(&payload).unwrap();
    let mut rows: c_uint = 0;
    let r = odbc_bulk_insert_array(
        TEST_INVALID_ID,
        std::ptr::null(),
        std::ptr::null(),
        0,
        enc.as_ptr(),
        enc.len() as c_uint,
        0,
        &mut rows,
    );

    assert_eq!(r, -1, "Invalid conn_id should return -1 after v2 parse");
    let err = get_last_error();
    assert!(
        err.contains("Invalid handle") || err.contains(&TEST_INVALID_ID.to_string()),
        "v2 payload should parse before connection lookup, got: {}",
        err
    );
}

#[test]
fn test_bulk_parallel_row_chunk_ranges_cover_all_rows() {
    assert_eq!(row_chunk_ranges(0, 4), Vec::<(usize, usize)>::new());
    assert_eq!(row_chunk_ranges(5, 1), vec![(0, 5)]);
    assert_eq!(row_chunk_ranges(5, 2), vec![(0, 3), (3, 5)]);
    assert_eq!(
        row_chunk_ranges(5, 8),
        vec![(0, 1), (1, 2), (2, 3), (3, 4), (4, 5)]
    );
}

#[test]
#[cfg(feature = "sqlserver-bcp")]
fn test_bulk_parallel_bcp_chunk_fallback_preserves_binary_nul() {
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "blob".to_string(),
            col_type: BulkColumnType::Binary,
            nullable: true,
            max_len: 8,
        }],
        row_count: 3,
        column_data: vec![BulkColumnData::Binary {
            rows: crate::protocol::bulk_rows_from_vecs(vec![vec![1], vec![2, 0, 3], vec![4]]),
            max_len: 8,
            null_bitmap: Some(vec![0]),
        }],
    };

    let chunk = slice_payload_rows(&payload, 1, 2).unwrap();
    assert_eq!(chunk.row_count, 1);
    match &chunk.column_data[0] {
        BulkColumnData::Binary { rows, .. } => assert_eq!(rows[0].as_slice(), &[2, 0, 3][..]),
        other => panic!("unexpected chunk data: {other:?}"),
    }
}

#[test]
fn test_ffi_bulk_insert_invalid_payload() {
    odbc_init();
    let mut rows: c_uint = 0;
    let truncated = [0u8, 0, 0, 0];
    let r = odbc_bulk_insert_array(
        1,
        std::ptr::null(),
        std::ptr::null(),
        0,
        truncated.as_ptr(),
        truncated.len() as c_uint,
        0,
        &mut rows,
    );
    assert_eq!(r, -1, "Truncated payload should return -1");
}

#[test]
#[serial(ffi_last_error)]
fn test_ffi_bulk_insert_parallel_null_buffer() {
    odbc_init();
    let mut rows: c_uint = 0;
    let r = odbc_bulk_insert_parallel(
        1,
        std::ptr::null(),
        std::ptr::null(),
        0,
        std::ptr::null(),
        16,
        2,
        &mut rows,
    );
    assert_eq!(r, -1, "Null data_buffer should return -1");
}

#[test]
#[serial(ffi_last_error)]
fn test_ffi_bulk_insert_parallel_null_rows_inserted() {
    odbc_init();
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "a".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: 1,
        column_data: vec![BulkColumnData::I32 {
            values: vec![1],
            null_bitmap: None,
        }],
    };
    let enc = serialize_bulk_insert_payload(&payload).unwrap();
    let r = odbc_bulk_insert_parallel(
        1,
        std::ptr::null(),
        std::ptr::null(),
        0,
        enc.as_ptr(),
        enc.len() as c_uint,
        2,
        std::ptr::null_mut(),
    );
    assert_eq!(r, -1, "Null rows_inserted should return -1");
}

#[test]
#[serial(ffi_last_error)]
fn test_ffi_bulk_insert_parallel_zero_len() {
    odbc_init();
    let mut rows: c_uint = 0;
    let buf = [0u8; 8];
    let r = odbc_bulk_insert_parallel(
        1,
        std::ptr::null(),
        std::ptr::null(),
        0,
        buf.as_ptr(),
        0,
        2,
        &mut rows,
    );
    assert_eq!(r, -1, "Zero buffer_len should return -1");
}

#[test]
#[serial(ffi_last_error)]
fn test_ffi_bulk_insert_parallel_invalid_pool() {
    odbc_init();
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "a".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: 1,
        column_data: vec![BulkColumnData::I32 {
            values: vec![1],
            null_bitmap: None,
        }],
    };
    let enc = serialize_bulk_insert_payload(&payload).unwrap();
    let mut rows: c_uint = 0;
    let r = odbc_bulk_insert_parallel(
        TEST_INVALID_ID,
        std::ptr::null(),
        std::ptr::null(),
        0,
        enc.as_ptr(),
        enc.len() as c_uint,
        2,
        &mut rows,
    );
    assert_eq!(r, -1, "Invalid pool_id should return -1");
}

#[test]
#[serial(ffi_last_error)]
fn test_ffi_bulk_insert_parallel_zero_parallelism() {
    odbc_init();
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "a".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: 1,
        column_data: vec![BulkColumnData::I32 {
            values: vec![1],
            null_bitmap: None,
        }],
    };
    let enc = serialize_bulk_insert_payload(&payload).unwrap();
    let mut rows: c_uint = 0;
    let r = odbc_bulk_insert_parallel(
        1,
        std::ptr::null(),
        std::ptr::null(),
        0,
        enc.as_ptr(),
        enc.len() as c_uint,
        0,
        &mut rows,
    );
    assert_eq!(r, -1, "parallelism=0 should return -1");
}

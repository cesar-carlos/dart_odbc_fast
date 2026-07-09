//! FFI `transaction` tests.

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
fn test_ffi_transaction_begin_invalid_conn() {
    odbc_init();

    let invalid_id = next_test_invalid_id();
    let txn_id = odbc_transaction_begin(invalid_id, 1, 0);
    assert_eq!(txn_id, 0, "Invalid connection ID should return 0");

    let error = get_last_error();
    let id_str = invalid_id.to_string();
    assert!(
        (error.contains("Invalid connection ID") && error.contains(&id_str))
            || error.contains("Invalid"),
        "Should have error message for invalid conn/txn: {}",
        error
    );
}

#[test]
fn test_ffi_transaction_begin_invalid_isolation() {
    odbc_init();

    let txn_id = odbc_transaction_begin(TEST_INVALID_ID, 99, 0);
    assert_eq!(txn_id, 0, "Invalid isolation level should return 0");
}

#[test]
fn test_ffi_transaction_commit_invalid_txn_id() {
    odbc_init();

    let invalid_id = next_test_invalid_id();
    let result = odbc_transaction_commit(invalid_id);
    assert_ne!(result, 0, "Invalid transaction ID should fail");

    let error = get_last_error();
    assert!(
        (error.contains("Invalid transaction ID") && error.contains(&invalid_id.to_string()))
            || error.contains("Invalid"),
        "Should have error message: {}",
        error
    );
}

#[test]
fn test_ffi_transaction_rollback_invalid_txn_id() {
    odbc_init();

    let invalid_id = next_test_invalid_id();
    let result = odbc_transaction_rollback(invalid_id);
    assert_ne!(result, 0, "Invalid transaction ID should fail");

    let error = get_last_error();
    assert!(
        (error.contains("Invalid transaction ID") && error.contains(&invalid_id.to_string()))
            || error.contains("Invalid"),
        "Should have error message: {}",
        error
    );
}

#[test]
fn test_ffi_transaction_workflow() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let txn_id = odbc_transaction_begin(conn_id, 1, 0);
    assert!(txn_id > 0);

    let cr = odbc_transaction_commit(txn_id);
    assert_eq!(cr, 0);

    let dr = odbc_disconnect(conn_id);
    assert_eq!(dr, 0);
}

/// Regression: when `Arc::try_unwrap` failed because a concurrent savepoint
/// call still held a clone, commit used to drop the registry handle — the
/// transaction vanished ("Invalid transaction ID" on retry) and the surviving
/// clone auto-rolled back committed-in-flight work via `Drop`. The busy
/// transaction must stay registered so the caller can retry.
#[test]
#[serial(ffi_pool_txn)]
fn should_keep_transaction_registered_when_commit_races_savepoint_clone() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let txn_id = odbc_transaction_begin(conn_id, 1, 0);
    assert!(txn_id > 0);

    // Simulate a concurrent savepoint call holding a clone of the handle.
    let concurrent_clone =
        state::get_transaction_for_test(txn_id).expect("transaction registered after begin");

    let busy_commit = odbc_transaction_commit(txn_id);
    assert_eq!(busy_commit, 1, "busy transaction commit should fail");

    assert!(
        state::contains_transaction_for_test(txn_id),
        "busy transaction must stay registered for retry"
    );

    drop(concurrent_clone);
    let retry_commit = odbc_transaction_commit(txn_id);
    assert_eq!(retry_commit, 0, "retry after clone release should commit");

    let dr = odbc_disconnect(conn_id);
    assert_eq!(dr, 0);
}

#[test]
#[serial(ffi_pool_txn)]
fn test_ffi_transaction_begin_rejects_concurrent_begin_on_same_connection() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let conn_id = odbc_connect(conn_cstr.as_ptr());
    assert!(conn_id > 0);

    let barrier = Arc::new(Barrier::new(3));
    let mut threads = Vec::new();
    for _ in 0..2 {
        let barrier = Arc::clone(&barrier);
        threads.push(std::thread::spawn(move || {
            barrier.wait();
            odbc_transaction_begin_v3(
                conn_id,
                IsolationLevel::ReadCommitted as c_uint,
                SavepointDialect::Auto as c_uint,
                TransactionAccessMode::ReadWrite as c_uint,
                0,
            )
        }));
    }

    barrier.wait();
    let results: Vec<u32> = threads
        .into_iter()
        .map(|handle| handle.join().expect("join concurrent begin thread"))
        .collect();
    let success_ids: Vec<u32> = results.iter().copied().filter(|id| *id > 0).collect();
    let failure_count = results.iter().filter(|id| **id == 0).count();

    assert_eq!(success_ids.len(), 1, "exactly one begin should succeed");
    assert_eq!(failure_count, 1, "exactly one begin should fail");

    let rollback = odbc_transaction_rollback(success_ids[0]);
    assert_eq!(
        rollback, 0,
        "winning transaction should be rolled back cleanly"
    );

    let disconnect = odbc_disconnect(conn_id);
    assert_eq!(disconnect, 0);
}

//! FFI `pool` tests.

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
    run_pooled_stream_case, structured_error_test_lock,
    trigger_structured_cancel_unsupported_error, with_structured_error_test_isolation,
    TEST_INVALID_ID,
};

#[test]
fn test_ffi_pool_create_null_conn_str() {
    let pool_id = odbc_pool_create(std::ptr::null(), 10);
    assert_eq!(pool_id, 0, "Null connection string should return 0");
}

#[test]
fn test_ffi_pool_create_invalid_conn_str() {
    // Invalid UTF-8 string (this would require unsafe to create, so we test with empty string)
    let empty_str = CString::new("").unwrap();
    let pool_id = odbc_pool_create(empty_str.as_ptr(), 10);

    // Should fail because empty connection string is invalid
    assert_eq!(pool_id, 0, "Empty connection string should return 0");

    let error = get_last_error();
    assert!(
        error.contains("odbc_pool_create failed") || error.contains("Pool creation failed"),
        "Should have error message: {}",
        error
    );
}

#[test]
fn test_ffi_pool_get_connection_invalid_pool_id() {
    odbc_init();

    let conn_id = odbc_pool_get_connection(TEST_INVALID_ID);
    assert_eq!(conn_id, 0, "Invalid pool ID should return 0");

    // Note: Error message may be from previous test due to global state
    // We just verify that the function returns 0 (failure)
    // The actual error message check is less strict due to state persistence
}

#[test]
fn test_ffi_pool_release_connection_invalid_id() {
    odbc_init();

    let result = odbc_pool_release_connection(TEST_INVALID_ID);
    assert_ne!(result, 0, "Invalid pooled connection ID should fail");

    // Note: Error message may be from previous test due to global state
    // We just verify that the function returns non-zero (failure)
}

#[test]
fn test_ffi_pool_health_check_invalid_pool_id() {
    odbc_init();

    let result = odbc_pool_health_check(TEST_INVALID_ID);
    assert_eq!(result, -1, "Invalid pool ID should return -1");
}

#[test]
fn test_ffi_pool_get_state_null_out_size() {
    let mut idle: c_uint = 0;

    let result = odbc_pool_get_state(1, std::ptr::null_mut(), &mut idle);
    assert_eq!(result, -1, "Null out_size should return -1");
}

#[test]
fn test_ffi_pool_get_state_null_out_idle() {
    let mut size: c_uint = 0;

    let result = odbc_pool_get_state(1, &mut size, std::ptr::null_mut());
    assert_eq!(result, -1, "Null out_idle should return -1");
}

#[test]
fn test_ffi_pool_get_state_invalid_pool_id() {
    odbc_init();

    let mut size: c_uint = 99;
    let mut idle: c_uint = 99;

    let result = odbc_pool_get_state(TEST_INVALID_ID, &mut size, &mut idle);
    assert_eq!(result, -1, "Invalid pool ID should return -1");
    assert_eq!(size, 0, "out_size should be zeroed on error");
    assert_eq!(idle, 0, "out_idle should be zeroed on error");
}

#[test]
fn test_ffi_pool_get_state_json_null_buffer() {
    odbc_init();

    let mut out: c_uint = 0;
    let result = odbc_pool_get_state_json(1, std::ptr::null_mut(), 256, &mut out);
    assert_eq!(result, -1, "Null buffer should return -1");
}

#[test]
fn test_ffi_pool_get_state_json_null_out_written() {
    odbc_init();

    let mut buf = [0u8; 256];
    let result = odbc_pool_get_state_json(1, buf.as_mut_ptr(), 256, std::ptr::null_mut());
    assert_eq!(result, -1, "Null out_written should return -1");
}

#[test]
fn test_ffi_pool_get_state_json_invalid_pool_id() {
    odbc_init();

    let mut buf = [0u8; 256];
    let mut out: c_uint = 0;
    let result = odbc_pool_get_state_json(TEST_INVALID_ID, buf.as_mut_ptr(), 256, &mut out);
    assert_eq!(result, -1, "Invalid pool ID should return -1");
    assert_eq!(out, 0, "out_written should be 0 on error");
}

#[test]
fn test_ffi_pool_set_size_zero_rejected() {
    odbc_init();

    let result = odbc_pool_set_size(1, 0);
    assert_eq!(result, -1, "new_max_size 0 should return -1");
}

#[test]
fn test_ffi_pool_set_size_invalid_pool_id() {
    odbc_init();

    let result = odbc_pool_set_size(TEST_INVALID_ID, 5);
    assert_eq!(result, -1, "Invalid pool ID should return -1");
}

#[test]
fn test_ffi_pool_close_invalid_pool_id() {
    odbc_init();

    let result = odbc_pool_close(TEST_INVALID_ID);
    assert_ne!(result, 0, "Invalid pool ID should fail");

    // Note: Error message may be from previous test due to global state
    // We just verify that the function returns non-zero (failure)
}

#[test]
fn test_ffi_pool_workflow() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let pool_id = odbc_pool_create(conn_cstr.as_ptr(), 2);
    assert!(pool_id > 0);

    let pooled_id = odbc_pool_get_connection(pool_id);
    assert!(pooled_id > 0);

    let pr = odbc_pool_release_connection(pooled_id);
    assert_eq!(pr, 0);

    let cr = odbc_pool_close(pool_id);
    assert_eq!(cr, 0);
}

#[test]
fn test_ffi_pool_get_state_json_workflow() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let pool_id = odbc_pool_create(conn_cstr.as_ptr(), 2);
    assert!(pool_id > 0);

    let mut buf = [0u8; 512];
    let mut out: c_uint = 0;
    let r = odbc_pool_get_state_json(pool_id, buf.as_mut_ptr(), 512, &mut out);
    assert_eq!(r, 0, "odbc_pool_get_state_json should succeed");
    assert!(out > 0, "out_written should be positive");

    let json_str = std::str::from_utf8(&buf[..out as usize]).unwrap();
    assert!(json_str.contains("total_connections"));
    assert!(json_str.contains("idle_connections"));
    assert!(json_str.contains("active_connections"));
    assert!(json_str.contains("max_size"));

    let mut small_buf = [0u8; 8];
    let mut small_out: c_uint = 0;
    let r_small = odbc_pool_get_state_json(pool_id, small_buf.as_mut_ptr(), 8, &mut small_out);
    assert_eq!(r_small, -2, "Buffer too small should return -2");
    assert!(
        small_out > small_buf.len() as c_uint,
        "Should report required JSON buffer size"
    );

    let cr = odbc_pool_close(pool_id);
    assert_eq!(cr, 0);
}

#[test]
fn test_ffi_pool_set_size_workflow() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let pool_id = odbc_pool_create(conn_cstr.as_ptr(), 2);
    assert!(pool_id > 0);

    let pooled_id = odbc_pool_get_connection(pool_id);
    assert!(pooled_id > 0);
    let r_with_conn = odbc_pool_set_size(pool_id, 5);
    assert_eq!(
        r_with_conn, -1,
        "Resize with checked-out connection should fail"
    );

    let pr = odbc_pool_release_connection(pooled_id);
    assert_eq!(pr, 0);

    let r_ok = odbc_pool_set_size(pool_id, 5);
    assert_eq!(r_ok, 0, "Resize after release should succeed");

    let mut size: c_uint = 0;
    let mut idle: c_uint = 0;
    let sr = odbc_pool_get_state(pool_id, &mut size, &mut idle);
    assert_eq!(sr, 0);
    assert_eq!(size, 5, "Pool max_size should be 5 after resize");

    let cr = odbc_pool_close(pool_id);
    assert_eq!(cr, 0);
}

#[test]
#[serial(ffi_pool_txn)]
fn test_ffi_pooled_connection_supports_batched_and_async_streams() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let pool_id = odbc_pool_create(conn_cstr.as_ptr(), 2);
    assert!(pool_id > 0);

    run_pooled_stream_case(pool_id, |pooled_id, sql| {
        odbc_stream_start_batched(pooled_id, sql, 1, 4096)
    });
    run_pooled_stream_case(pool_id, |pooled_id, sql| {
        odbc_stream_start_async(pooled_id, sql, 1, 4096)
    });
    run_pooled_stream_case(pool_id, |pooled_id, sql| {
        odbc_stream_multi_start_batched(pooled_id, sql, 4096)
    });
    run_pooled_stream_case(pool_id, |pooled_id, sql| {
        odbc_stream_multi_start_async(pooled_id, sql, 4096)
    });

    let close = odbc_pool_close(pool_id);
    assert_eq!(close, 0);
}

#[test]
#[serial(ffi_pool_txn)]
fn test_ffi_pooled_connection_supports_transactions() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let pool_id = odbc_pool_create(conn_cstr.as_ptr(), 2);
    assert!(pool_id > 0);

    let pooled_id = odbc_pool_get_connection(pool_id);
    assert!(pooled_id > 0);

    let txn_id = odbc_transaction_begin_v3(
        pooled_id,
        IsolationLevel::ReadCommitted as c_uint,
        SavepointDialect::Auto as c_uint,
        TransactionAccessMode::ReadWrite as c_uint,
        0,
    );
    assert!(
        txn_id > 0,
        "begin transaction on pooled connection should work"
    );

    let commit = odbc_transaction_commit(txn_id);
    assert_eq!(commit, 0, "commit on pooled transaction should succeed");

    let release = odbc_pool_release_connection(pooled_id);
    assert_eq!(release, 0);

    let close = odbc_pool_close(pool_id);
    assert_eq!(close, 0);
}

#[test]
#[serial(ffi_pool_txn)]
fn test_ffi_pool_release_invalidates_active_transaction() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let pool_id = odbc_pool_create(conn_cstr.as_ptr(), 2);
    assert!(pool_id > 0);

    let pooled_id = odbc_pool_get_connection(pool_id);
    assert!(pooled_id > 0);

    let txn_id = odbc_transaction_begin_v3(
        pooled_id,
        IsolationLevel::ReadCommitted as c_uint,
        SavepointDialect::Auto as c_uint,
        TransactionAccessMode::ReadWrite as c_uint,
        0,
    );
    assert!(txn_id > 0);

    let release = odbc_pool_release_connection(pooled_id);
    assert_eq!(release, 0, "release should cleanup the active transaction");

    let commit = odbc_transaction_commit(txn_id);
    assert_eq!(
        commit, 1,
        "stale transaction id must be invalid after release"
    );

    let close = odbc_pool_close(pool_id);
    assert_eq!(close, 0);
}

#[test]
fn test_ffi_pool_release_cleans_statements() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let pool_id = odbc_pool_create(conn_cstr.as_ptr(), 2);
    assert!(pool_id > 0);

    let pooled_id = odbc_pool_get_connection(pool_id);
    assert!(pooled_id > 0);

    let sql = CString::new("SELECT 1 AS n").unwrap();
    let stmt_id = odbc_prepare(pooled_id, sql.as_ptr(), 0);
    assert!(stmt_id > 0, "Prepare should succeed");

    let pr = odbc_pool_release_connection(pooled_id);
    assert_eq!(pr, 0, "Release should succeed");

    let mut buffer = vec![0u8; 2048];
    let mut written: c_uint = 0;
    let exec_result = odbc_execute(
        stmt_id,
        std::ptr::null(),
        0,
        0,
        0,
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    assert_ne!(
        exec_result, 0,
        "Execute with stale stmt_id after release should fail"
    );

    let cr = odbc_pool_close(pool_id);
    assert_eq!(cr, 0);
}

#[test]
fn test_ffi_pool_release_raii_rollback_autocommit() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set (ENABLE_E2E_TESTS=1)");
        return;
    };

    odbc_init();
    let conn_cstr = CString::new(dsn.as_str()).unwrap();
    let pool_id = odbc_pool_create(conn_cstr.as_ptr(), 2);
    assert!(pool_id > 0);

    let pooled_id = odbc_pool_get_connection(pool_id);
    assert!(pooled_id > 0);

    // Dirty the connection: flip autocommit off via the live Connection
    // handle. This mirrors what `Transaction::begin` does for non-pooled
    // connections; for the pool path we go straight to the wrapper.
    {
        let mut state = get_global_state().lock().unwrap();
        let entry = state
            .pooled_connections
            .get_mut(&pooled_id)
            .expect("just-acquired pooled connection must be in state");
        entry
            .pooled
            .lock()
            .expect("lock pooled connection for test")
            .get_connection_mut()
            .set_autocommit(false)
            .expect("set_autocommit(false) on pooled conn");
    }

    let pr = odbc_pool_release_connection(pooled_id);
    assert_eq!(
        pr, 0,
        "Release should succeed (RAII rollback + autocommit restore)"
    );

    let pooled_id2 = odbc_pool_get_connection(pool_id);
    assert!(pooled_id2 > 0);

    // The customizer must have rolled back + reset autocommit; a plain
    // SELECT must succeed without any "transaction state" complaint.
    let select_sql = CString::new("SELECT 1 AS n").unwrap();
    let mut buffer2 = vec![0u8; 2048];
    let mut written2: c_uint = 0;
    let select_result = odbc_exec_query(
        pooled_id2,
        select_sql.as_ptr(),
        buffer2.as_mut_ptr(),
        buffer2.len() as c_uint,
        &mut written2,
    );
    let err_msg = {
        let mut buf = vec![0i8; 2048];
        let n = odbc_get_error(buf.as_mut_ptr(), buf.len() as c_uint);
        if n > 0 {
            let bytes: Vec<u8> = buf[..n as usize].iter().map(|b| *b as u8).collect();
            String::from_utf8_lossy(&bytes).to_string()
        } else {
            "<empty>".to_string()
        }
    };
    assert_eq!(
        select_result, 0,
        "SELECT after release should succeed (clean connection); err = {err_msg}"
    );
    assert!(written2 > 0, "Should have result data");

    let _ = odbc_pool_release_connection(pooled_id2);
    let cr = odbc_pool_close(pool_id);
    assert_eq!(cr, 0);
}

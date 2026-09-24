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
use odbc_api::Cursor;
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
    assert_eq!(
        busy_commit, 2,
        "busy transaction commit should be retryable"
    );
    assert_eq!(
        odbc_disconnect(conn_id),
        1,
        "disconnect must not remove a borrowed transaction"
    );
    assert_eq!(
        odbc_transaction_begin(conn_id, 1, 0),
        0,
        "begin must not overlap a borrowed transaction"
    );

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
fn should_keep_connection_reserved_during_transaction_finish() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("Skipping: ODBC_TEST_DSN not set");
        return;
    };
    odbc_init();
    let conn_id = odbc_connect(CString::new(dsn).unwrap().as_ptr());
    assert!(conn_id > 0);
    let txn_id = odbc_transaction_begin(conn_id, 1, 0);
    assert!(txn_id > 0);

    let txn = state::take_transaction_for_finish(txn_id).expect("finish reservation");
    assert_eq!(odbc_transaction_begin(conn_id, 1, 0), 0);
    assert_eq!(odbc_transaction_commit(txn_id), 2);
    assert_eq!(
        odbc_savepoint_create(txn_id, CString::new("sp").unwrap().as_ptr()),
        2
    );
    assert_eq!(odbc_disconnect(conn_id), 1);
    txn.rollback().expect("rollback claimed transaction");
    state::finish_transaction(conn_id, txn_id);
    assert_eq!(odbc_disconnect(conn_id), 0);
}

#[test]
#[serial(ffi_pool_txn)]
#[cfg(feature = "statement-handle-reuse")]
fn should_preserve_prepared_cache_only_when_driver_retains_prepared_plans() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("Skipping: ODBC_TEST_DSN not set");
        return;
    };
    odbc_init();
    let conn_id = odbc_connect(CString::new(dsn).unwrap().as_ptr());
    assert!(conn_id > 0);
    let handles = state::connection_handles(conn_id).expect("regular connection");
    let cached_arc = handles.lock().unwrap().get_connection(conn_id).unwrap();
    let behavior = {
        let cached = cached_arc.lock().unwrap();
        crate::engine::odbc_get_info::transaction_cursor_behavior(cached.connection())
    };
    for commit in [true, false] {
        {
            let mut cached = cached_arc.lock().unwrap();
            cached
                .execute_query_no_params("SELECT 1 AS n")
                .expect("prepare query");
            assert!(cached.tracked_sql_entries() > 0);
        }
        let txn_id = odbc_transaction_begin(conn_id, 1, 0);
        assert!(txn_id > 0);
        let status = if commit {
            odbc_transaction_commit(txn_id)
        } else {
            odbc_transaction_rollback(txn_id)
        };
        assert_eq!(status, 0);
        let cached = cached_arc.lock().unwrap();
        let reported = if commit { behavior.0 } else { behavior.1 };
        let preserve = crate::engine::odbc_get_info::cursor_behavior_preserves_prepared(reported);
        assert_eq!(cached.tracked_sql_entries() > 0, preserve);
    }
    drop(cached_arc);
    assert_eq!(odbc_disconnect(conn_id), 0);
}

#[test]
#[serial(ffi_pool_txn)]
#[cfg(not(feature = "statement-handle-reuse"))]
fn should_bind_multi_stream_parameters_without_statement_cache() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("Skipping: ODBC_TEST_DSN not set");
        return;
    };
    odbc_init();
    let conn_id = odbc_connect(CString::new(dsn).unwrap().as_ptr());
    assert!(conn_id > 0);
    let sql = CString::new("SELECT ? AS n").unwrap();
    let params = serialize_params(&[ParamValue::Integer(42)]);
    let stream_id = odbc_stream_multi_start_batched_params_options(
        conn_id,
        sql.as_ptr(),
        params.as_ptr(),
        params.len() as u32,
        100,
        4096,
        0,
    );
    assert!(stream_id > 0);
    let mut output = vec![0u8; 4096];
    let mut written = 0;
    let mut more = 0;
    assert_eq!(
        odbc_stream_fetch(
            stream_id,
            output.as_mut_ptr(),
            output.len() as u32,
            &mut written,
            &mut more
        ),
        0
    );
    assert!(written > 0, "bound MULT result must produce a frame");
    assert_eq!(odbc_stream_close(stream_id), 0);
    assert_eq!(odbc_disconnect(conn_id), 0);
}

#[test]
#[serial(ffi_pool_txn)]
#[cfg(feature = "test-helpers")]
fn should_apply_postgres_settings_inside_the_started_transaction() {
    crate::test_helpers::load_dotenv();
    let Ok(dsn) = std::env::var("ODBC_TEST_PG_DSN") else {
        eprintln!("Skipping: ODBC_TEST_PG_DSN not set");
        return;
    };
    if dsn.is_empty() {
        eprintln!("Skipping: ODBC_TEST_PG_DSN empty");
        return;
    }
    odbc_init();
    let conn_id = odbc_connect(CString::new(dsn).unwrap().as_ptr());
    assert!(conn_id > 0);
    let txn_id = odbc_transaction_begin_v3(conn_id, 3, 0, 1, 1750);
    assert!(txn_id > 0, "PostgreSQL transaction should begin");
    let handles = state::connection_handles(conn_id).unwrap();
    let cached_arc = handles.lock().unwrap().get_connection(conn_id).unwrap();
    {
        let cached = cached_arc.lock().unwrap();
        let mut cursor = cached.connection()
            .execute("SELECT current_setting('transaction_read_only'), current_setting('transaction_isolation'), current_setting('lock_timeout')", (), None)
            .expect("settings query")
            .expect("settings cursor");
        let mut row = cursor
            .next_row()
            .expect("fetch settings")
            .expect("one settings row");
        let mut value = Vec::new();
        row.get_text(1, &mut value).expect("read-only setting");
        assert_eq!(String::from_utf8_lossy(&value), "on");
        row.get_text(2, &mut value).expect("isolation setting");
        assert_eq!(String::from_utf8_lossy(&value), "serializable");
        row.get_text(3, &mut value).expect("timeout setting");
        assert_eq!(String::from_utf8_lossy(&value), "1750ms");
    }
    assert_eq!(odbc_transaction_rollback(txn_id), 0);
    drop(cached_arc);
    assert_eq!(odbc_disconnect(conn_id), 0);
}

#[test]
#[serial(ffi_pool_txn)]
fn should_restore_sql_server_session_isolation_for_next_pool_user() {
    let Some(dsn) = ffi_test_dsn() else {
        eprintln!("Skipping: ODBC_TEST_DSN not set");
        return;
    };
    if !super::support::ffi_test_dsn_is_sql_server(&dsn) {
        eprintln!("Skipping: SQL Server DSN required");
        return;
    }
    odbc_init();
    let pool_id = odbc_pool_create(CString::new(dsn).unwrap().as_ptr(), 1);
    assert!(pool_id > 0);
    let conn_id = odbc_pool_get_connection(pool_id);
    assert!(conn_id > 0);
    let txn_id = odbc_transaction_begin(conn_id, IsolationLevel::Serializable as u32, 0);
    assert!(txn_id > 0);
    assert_eq!(odbc_transaction_commit(txn_id), 0);
    assert_eq!(odbc_pool_release_connection(conn_id), 0);

    let next_conn_id = odbc_pool_get_connection(pool_id);
    assert!(next_conn_id > 0);
    let pooled = state::get_pooled_connection(next_conn_id).expect("pooled connection");
    {
        let guard = pooled.pooled.lock().unwrap();
        let mut cursor = guard
            .get_connection()
            .execute(
                "SELECT CAST(transaction_isolation_level AS INT) FROM sys.dm_exec_sessions WHERE session_id = @@SPID",
                (),
                None,
            )
            .expect("session isolation query")
            .expect("session isolation cursor");
        let mut row = cursor.next_row().expect("fetch").expect("one row");
        let mut value = Vec::new();
        row.get_text(1, &mut value).expect("isolation value");
        assert_eq!(String::from_utf8_lossy(&value), "2");
    }
    assert_eq!(odbc_pool_release_connection(next_conn_id), 0);
    assert_eq!(odbc_pool_close(pool_id), 0);
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

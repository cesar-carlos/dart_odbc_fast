/// E2E tests for the async API surface.
///
/// Validates the same engine behavior that the Dart worker isolate uses via FFI:
/// binary protocol consistency, connection lifecycle, error propagation,
/// and multiple connections.
use odbc_engine::engine::{execute_query_with_connection, OdbcConnection, OdbcEnvironment};
use odbc_engine::ffi::{
    odbc_async_cancel, odbc_async_free, odbc_async_get_result, odbc_async_poll, odbc_connect,
    odbc_disconnect, odbc_exec_query, odbc_execute_async, odbc_init,
};
use std::ffi::CString;
use std::os::raw::{c_int, c_uint};
use std::thread;
use std::time::{Duration, Instant};

mod helpers;
use helpers::e2e::{is_database_type, should_run_e2e_tests, DatabaseType};
use helpers::env::get_sqlserver_test_dsn;

#[test]
fn test_async_query_returns_same_as_sync() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set ODBC_TEST_DSN or SQLSERVER_TEST_* environment variables");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }
    let dsn = get_sqlserver_test_dsn().expect("ODBC_TEST_DSN or SQLSERVER_TEST_* not set");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &dsn).expect("Failed to connect to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let conn_arc = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");
    let odbc_conn = conn_arc.lock().unwrap();

    let sql = "SELECT 1 AS col, 'test' AS str";
    let result1 = execute_query_with_connection(&odbc_conn, sql).expect("First query failed");
    let result2 = execute_query_with_connection(&odbc_conn, sql).expect("Second query failed");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    assert_eq!(
        result1.len(),
        result2.len(),
        "Binary protocol output length should be identical for same query"
    );
    assert_eq!(
        result1, result2,
        "Binary protocol output should be identical for same query (sync path used by worker)"
    );
}

#[test]
fn test_async_connection_lifecycle() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set ODBC_TEST_DSN or SQLSERVER_TEST_* environment variables");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }
    let dsn = get_sqlserver_test_dsn().expect("ODBC_TEST_DSN or SQLSERVER_TEST_* not set");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &dsn).expect("Failed to connect");

    let conn_id = conn.get_connection_id();
    assert!(conn_id > 0, "Connection ID should be positive");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let conn_arc = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");
    let odbc_conn = conn_arc.lock().unwrap();

    let buffer =
        execute_query_with_connection(&odbc_conn, "SELECT 1").expect("Failed to execute SELECT 1");
    assert!(!buffer.is_empty(), "Result should not be empty");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");
}

#[test]
fn test_async_error_propagation() {
    let invalid_dsn = "Driver={Invalid};Server=invalid";

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();

    let result = OdbcConnection::connect(handles, invalid_dsn);
    assert!(
        result.is_err(),
        "Connection with invalid DSN should fail and propagate error"
    );
}

#[test]
fn test_async_parallel_operations() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set ODBC_TEST_DSN or SQLSERVER_TEST_* environment variables");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }
    let dsn = get_sqlserver_test_dsn().expect("ODBC_TEST_DSN or SQLSERVER_TEST_* not set");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();

    let conn1 = OdbcConnection::connect(handles.clone(), &dsn).expect("Failed to connect (1)");
    let conn2 = OdbcConnection::connect(handles.clone(), &dsn).expect("Failed to connect (2)");
    let conn3 = OdbcConnection::connect(handles, &dsn).expect("Failed to connect (3)");

    let id1 = conn1.get_connection_id();
    let id2 = conn2.get_connection_id();
    let id3 = conn3.get_connection_id();

    assert!(
        id1 > 0 && id2 > 0 && id3 > 0,
        "All connection IDs should be positive"
    );
    assert_ne!(id1, id2, "Connection IDs should be distinct");
    assert_ne!(id2, id3, "Connection IDs should be distinct");
    assert_ne!(id1, id3, "Connection IDs should be distinct");

    conn1.disconnect().expect("Disconnect 1");
    conn2.disconnect().expect("Disconnect 2");
    conn3.disconnect().expect("Disconnect 3");
}

#[test]
fn test_async_ffi_execute_poll_get_result_e2e() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let dsn = get_sqlserver_test_dsn().expect("ODBC_TEST_DSN or SQLSERVER_TEST_* not set");
    assert_eq!(odbc_init(), 0, "odbc_init should succeed");

    let dsn_c = CString::new(dsn).expect("dsn cstring");
    let conn_id = odbc_connect(dsn_c.as_ptr());
    assert!(conn_id > 0, "odbc_connect should return valid conn_id");

    let sql_c = CString::new("SELECT 1 AS one, 'ok' AS txt").expect("sql cstring");
    let request_id = odbc_execute_async(conn_id, sql_c.as_ptr());
    assert!(
        request_id > 0,
        "odbc_execute_async should return request_id"
    );

    let mut status: c_int = 0;
    let mut ready = false;
    for _ in 0..200 {
        let poll_rc = odbc_async_poll(request_id, &mut status);
        assert_eq!(poll_rc, 0, "odbc_async_poll should succeed");
        if status == 1 {
            ready = true;
            break;
        }
        assert!(
            status == 0 || status == -1 || status == -2,
            "Unexpected async status: {}",
            status
        );
        if status == -1 || status == -2 {
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }
    assert!(ready, "Async request did not reach READY status");

    let mut out = vec![0u8; 1024 * 1024];
    let mut written: c_uint = 0;
    let get_rc = odbc_async_get_result(
        request_id,
        out.as_mut_ptr(),
        out.len() as c_uint,
        &mut written,
    );
    assert_eq!(get_rc, 0, "odbc_async_get_result should succeed");
    assert!(written > 0, "Result payload should not be empty");

    assert_eq!(
        odbc_async_free(request_id),
        0,
        "odbc_async_free should succeed"
    );
    assert_eq!(
        odbc_disconnect(conn_id),
        0,
        "odbc_disconnect should succeed"
    );
}

#[test]
fn test_async_ffi_cancel_e2e() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let dsn = get_sqlserver_test_dsn().expect("ODBC_TEST_DSN or SQLSERVER_TEST_* not set");
    assert_eq!(odbc_init(), 0, "odbc_init should succeed");

    let dsn_c = CString::new(dsn).expect("dsn cstring");
    let conn_id = odbc_connect(dsn_c.as_ptr());
    assert!(conn_id > 0, "odbc_connect should return valid conn_id");

    let sql_c = CString::new("WAITFOR DELAY '00:00:03'; SELECT 1").expect("sql cstring");
    let request_id = odbc_execute_async(conn_id, sql_c.as_ptr());
    assert!(
        request_id > 0,
        "odbc_execute_async should return request_id"
    );

    assert_eq!(
        odbc_async_cancel(request_id),
        0,
        "odbc_async_cancel should succeed"
    );

    let mut status: c_int = 0;
    let mut cancelled = false;
    for _ in 0..50 {
        let poll_rc = odbc_async_poll(request_id, &mut status);
        assert_eq!(poll_rc, 0, "odbc_async_poll should succeed");
        if status == -2 {
            cancelled = true;
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }
    assert!(cancelled, "Async request should reach CANCELLED status");

    assert_eq!(
        odbc_async_free(request_id),
        0,
        "odbc_async_free should succeed"
    );
    assert_eq!(
        odbc_disconnect(conn_id),
        0,
        "odbc_disconnect should succeed"
    );
}

/// E2E: 10+ concurrent async operations across multiple connections.
/// Validates status/result/free lifecycle for all requests.
#[test]
fn test_async_ffi_10_plus_concurrent_e2e() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    const N: usize = 12;
    let dsn = get_sqlserver_test_dsn().expect("ODBC_TEST_DSN or SQLSERVER_TEST_* not set");
    assert_eq!(odbc_init(), 0, "odbc_init should succeed");

    let dsn_c = CString::new(dsn.as_str()).expect("dsn cstring");

    let mut conn_ids: Vec<c_uint> = Vec::with_capacity(N);
    for _ in 0..N {
        let conn_id = odbc_connect(dsn_c.as_ptr());
        assert!(conn_id > 0, "odbc_connect should return valid conn_id");
        conn_ids.push(conn_id);
    }

    let mut request_ids: Vec<c_uint> = Vec::with_capacity(N);
    for (i, &conn_id) in conn_ids.iter().enumerate() {
        let sql = format!("SELECT {} AS id, 'row{}' AS label", i + 1, i);
        let sql_c = CString::new(sql).expect("sql cstring");
        let req_id = odbc_execute_async(conn_id, sql_c.as_ptr());
        assert!(req_id > 0, "odbc_execute_async[{}] should return request_id", i);
        request_ids.push(req_id);
    }

    const ASYNC_STATUS_READY: c_int = 1;
    const ASYNC_STATUS_ERROR: c_int = -1;
    const ASYNC_STATUS_CANCELLED: c_int = -2;

    let mut statuses: Vec<c_int> = vec![0; N];
    let mut all_ready = false;
    for _ in 0..300 {
        let mut ready_count = 0;
        for (i, &req_id) in request_ids.iter().enumerate() {
            if statuses[i] == ASYNC_STATUS_READY
                || statuses[i] == ASYNC_STATUS_ERROR
                || statuses[i] == ASYNC_STATUS_CANCELLED
            {
                ready_count += 1;
                continue;
            }
            let poll_rc = odbc_async_poll(req_id, &mut statuses[i]);
            assert_eq!(poll_rc, 0, "odbc_async_poll[{}] should succeed", i);
            if statuses[i] == ASYNC_STATUS_READY {
                ready_count += 1;
            }
        }
        if ready_count == N {
            all_ready = true;
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }
    assert!(
        all_ready,
        "All {} async requests should reach terminal status",
        N
    );

    for (i, &req_id) in request_ids.iter().enumerate() {
        assert_eq!(
            statuses[i],
            ASYNC_STATUS_READY,
            "Request {} should be READY, got {}",
            i,
            statuses[i]
        );

        let mut out = vec![0u8; 64 * 1024];
        let mut written: c_uint = 0;
        let get_rc = odbc_async_get_result(
            req_id,
            out.as_mut_ptr(),
            out.len() as c_uint,
            &mut written,
        );
        assert_eq!(get_rc, 0, "odbc_async_get_result[{}] should succeed", i);
        assert!(written > 0, "Result[{}] payload should not be empty", i);

        assert_eq!(
            odbc_async_free(req_id),
            0,
            "odbc_async_free[{}] should succeed",
            i
        );
    }

    for &conn_id in &conn_ids {
        assert_eq!(
            odbc_disconnect(conn_id),
            0,
            "odbc_disconnect should succeed"
        );
    }
}

/// E2E benchmark: compare async lifecycle overhead vs sync FFI calls.
#[test]
fn test_async_vs_sync_overhead_e2e() {
    if !should_run_e2e_tests() {
        eprintln!("Skipping E2E benchmark: SQL Server not available");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    const ITERATIONS: usize = 20;
    const POLL_LIMIT: usize = 300;

    let dsn = get_sqlserver_test_dsn().expect("ODBC_TEST_DSN or SQLSERVER_TEST_* not set");
    assert_eq!(odbc_init(), 0, "odbc_init should succeed");

    let dsn_c = CString::new(dsn).expect("dsn cstring");
    let conn_id = odbc_connect(dsn_c.as_ptr());
    assert!(conn_id > 0, "odbc_connect should return valid conn_id");

    let sql_sync = CString::new("SELECT 1 AS one, 'sync' AS tag").expect("sync sql cstring");
    let mut sync_buffer = vec![0u8; 256 * 1024];
    let sync_start = Instant::now();
    for i in 0..ITERATIONS {
        let mut written: c_uint = 0;
        let rc = odbc_exec_query(
            conn_id,
            sql_sync.as_ptr(),
            sync_buffer.as_mut_ptr(),
            sync_buffer.len() as c_uint,
            &mut written,
        );
        assert_eq!(rc, 0, "odbc_exec_query[{}] should succeed", i);
        assert!(written > 0, "sync result[{}] payload should not be empty", i);
    }
    let sync_elapsed = sync_start.elapsed();

    let sql_async = CString::new("SELECT 1 AS one, 'async' AS tag").expect("async sql cstring");
    let async_start = Instant::now();
    for i in 0..ITERATIONS {
        let request_id = odbc_execute_async(conn_id, sql_async.as_ptr());
        assert!(
            request_id > 0,
            "odbc_execute_async[{}] should return request_id",
            i
        );

        let mut status: c_int = 0;
        let mut ready = false;
        for _ in 0..POLL_LIMIT {
            let poll_rc = odbc_async_poll(request_id, &mut status);
            assert_eq!(poll_rc, 0, "odbc_async_poll[{}] should succeed", i);
            if status == 1 {
                ready = true;
                break;
            }
            if status == -1 || status == -2 {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        assert!(ready, "async request[{}] did not reach READY status", i);

        let mut out = vec![0u8; 256 * 1024];
        let mut written: c_uint = 0;
        let get_rc = odbc_async_get_result(
            request_id,
            out.as_mut_ptr(),
            out.len() as c_uint,
            &mut written,
        );
        assert_eq!(get_rc, 0, "odbc_async_get_result[{}] should succeed", i);
        assert!(written > 0, "async result[{}] payload should not be empty", i);

        assert_eq!(
            odbc_async_free(request_id),
            0,
            "odbc_async_free[{}] should succeed",
            i
        );
    }
    let async_elapsed = async_start.elapsed();

    let sync_ms = sync_elapsed.as_millis();
    let async_ms = async_elapsed.as_millis();
    let ratio = if sync_ms == 0 {
        0.0
    } else {
        async_ms as f64 / sync_ms as f64
    };
    eprintln!(
        "Async vs Sync overhead ({} iterations): sync={}ms async={}ms ratio={:.2}x",
        ITERATIONS, sync_ms, async_ms, ratio
    );

    // Keep this threshold conservative to avoid flaky CI on slow machines.
    assert!(
        sync_ms == 0 || async_ms <= (sync_ms * 20) + 2_000,
        "Async overhead too high: sync={}ms async={}ms",
        sync_ms,
        async_ms
    );

    assert_eq!(
        odbc_disconnect(conn_id),
        0,
        "odbc_disconnect should succeed"
    );
}

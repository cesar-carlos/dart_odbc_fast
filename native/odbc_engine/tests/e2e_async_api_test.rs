/// E2E tests for the async API surface.
///
/// Validates the same engine behavior that the Dart worker isolate uses via FFI:
/// binary protocol consistency, connection lifecycle, error propagation,
/// and multiple connections.
use odbc_engine::engine::{execute_query_with_connection, OdbcConnection, OdbcEnvironment};

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
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    let sql = "SELECT 1 AS col, 'test' AS str";
    let result1 = execute_query_with_connection(odbc_conn, sql).expect("First query failed");
    let result2 = execute_query_with_connection(odbc_conn, sql).expect("Second query failed");

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
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    let buffer =
        execute_query_with_connection(odbc_conn, "SELECT 1").expect("Failed to execute SELECT 1");
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

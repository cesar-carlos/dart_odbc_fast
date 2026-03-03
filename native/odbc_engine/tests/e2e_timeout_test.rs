//! E2E tests for query timeout override.
//!
//! Validates that timeout_override_ms is applied correctly:
//! - Short timeout + long query → fails (timeout enforcement)
//! - Sufficient timeout + short query → succeeds (timeout success)
//!
//! Uses SQL Server WAITFOR DELAY; skips when not connected to SQL Server.

use odbc_engine::engine::{execute_query_with_params_and_timeout, OdbcConnection, OdbcEnvironment};

mod helpers;
use helpers::e2e::{is_database_type, should_run_e2e_tests, DatabaseType};
use helpers::get_sqlserver_test_dsn;

#[test]
fn test_timeout_enforcement_short_timeout_fails() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        eprintln!("⚠️  Skipping: WAITFOR DELAY is SQL Server specific");
        return;
    }

    let conn_str = get_sqlserver_test_dsn().expect("Failed to build connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");

    let conn_arc = conn
        .get_handles()
        .lock()
        .unwrap()
        .get_connection(conn.get_connection_id())
        .expect("get connection");
    let odbc_conn = conn_arc.lock().unwrap();

    // SQL Server: WAITFOR DELAY waits 3 seconds
    let sql = "WAITFOR DELAY '00:00:03'";
    let timeout_sec = Some(1);

    let result =
        execute_query_with_params_and_timeout(odbc_conn.connection(), sql, &[], timeout_sec, None);

    drop(odbc_conn);
    conn.disconnect().expect("disconnect");

    assert!(
        result.is_err(),
        "Query with 1s timeout should fail for 3s WAITFOR"
    );
}

#[test]
fn test_timeout_success_sufficient_timeout_succeeds() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        eprintln!("⚠️  Skipping: WAITFOR DELAY is SQL Server specific");
        return;
    }

    let conn_str = get_sqlserver_test_dsn().expect("Failed to build connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");

    let conn_arc = conn
        .get_handles()
        .lock()
        .unwrap()
        .get_connection(conn.get_connection_id())
        .expect("get connection");
    let odbc_conn = conn_arc.lock().unwrap();

    // SQL Server: WAITFOR DELAY waits 1 second
    let sql = "WAITFOR DELAY '00:00:01'";
    let timeout_sec = Some(5);

    let result =
        execute_query_with_params_and_timeout(odbc_conn.connection(), sql, &[], timeout_sec, None);

    drop(odbc_conn);
    conn.disconnect().expect("disconnect");

    assert!(
        result.is_ok(),
        "Query with 5s timeout should succeed for 1s WAITFOR"
    );
}

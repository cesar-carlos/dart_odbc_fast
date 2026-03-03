//! E2E basic tests that run against any configured database (SQL Server, PostgreSQL, MySQL).
//!
//! Set ENABLE_E2E_TESTS=1 and one of:
//! - ODBC_TEST_DSN (full connection string)
//! - ODBC_TEST_DB=postgres with POSTGRES_TEST_* (or docker defaults)
//! - ODBC_TEST_DB=mysql with MYSQL_TEST_* (or docker defaults)
//! - SQLSERVER_TEST_* (or defaults)

mod helpers;
use helpers::e2e::{get_connection_and_db_type, should_run_e2e_tests, sql_drop_table_if_exists};
use odbc_engine::engine::{execute_query_with_connection, OdbcConnection, OdbcEnvironment};
use odbc_engine::protocol::BinaryProtocolDecoder;

#[test]
fn test_multi_db_connect_disconnect() {
    if !should_run_e2e_tests() {
        eprintln!(
            "⚠️  Skipping: set ENABLE_E2E_TESTS=1 and configure ODBC_TEST_DSN or ODBC_TEST_DB"
        );
        return;
    }

    let (conn_str, db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect");
    conn.disconnect().expect("Failed to disconnect");

    eprintln!("✓ multi_db_connect_disconnect passed with {:?}", db_type);
}

#[test]
fn test_multi_db_select_one() {
    if !should_run_e2e_tests() {
        eprintln!(
            "⚠️  Skipping: set ENABLE_E2E_TESTS=1 and configure ODBC_TEST_DSN or ODBC_TEST_DB"
        );
        return;
    }

    let (conn_str, db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Failed to connect");
    let conn_id = conn.get_connection_id();

    let conn_arc = handles
        .lock()
        .expect("lock")
        .get_connection(conn_id)
        .expect("get_connection");
    let odbc_conn = conn_arc.lock().expect("lock");

    let buffer = execute_query_with_connection(odbc_conn.connection(), "SELECT 1 AS value")
        .expect("Failed to execute SELECT 1");
    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode result");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    conn.disconnect().expect("Failed to disconnect");
    eprintln!("✓ multi_db_select_one passed with {:?}", db_type);
}

#[test]
fn test_multi_db_create_drop_table() {
    if !should_run_e2e_tests() {
        eprintln!(
            "⚠️  Skipping: set ENABLE_E2E_TESTS=1 and configure ODBC_TEST_DSN or ODBC_TEST_DB"
        );
        return;
    }

    let (conn_str, db_type) =
        get_connection_and_db_type().expect("Failed to get connection string and database type");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("Failed to connect");
    let conn_id = conn.get_connection_id();

    let table = "odbc_multi_db_test";
    let drop_sql = sql_drop_table_if_exists(table, db_type);
    let create_sql = format!("CREATE TABLE {} (id INT)", table);

    {
        let conn_arc = handles
            .lock()
            .expect("lock")
            .get_connection(conn_id)
            .expect("get");
        let c = conn_arc.lock().expect("lock");
        execute_query_with_connection(c.connection(), &drop_sql).ok();
        execute_query_with_connection(c.connection(), &create_sql).expect("CREATE TABLE failed");
    }

    {
        let conn_arc = handles
            .lock()
            .expect("lock")
            .get_connection(conn_id)
            .expect("get");
        let c = conn_arc.lock().expect("lock");
        execute_query_with_connection(c.connection(), &format!("DROP TABLE {}", table))
            .expect("DROP TABLE failed");
    }

    conn.disconnect().expect("Failed to disconnect");
    eprintln!("✓ multi_db_create_drop_table passed with {:?}", db_type);
}

mod helpers;
use helpers::e2e::should_run_e2e_tests;
use helpers::get_sqlserver_test_dsn;
use odbc_engine::engine::{
    execute_query_with_connection, get_type_info, list_columns, list_tables, OdbcConnection,
    OdbcEnvironment,
};
use odbc_engine::BinaryProtocolDecoder;

#[test]
fn test_catalog_list_tables() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }

    let conn_str = get_sqlserver_test_dsn().expect("DSN");
    let env = OdbcEnvironment::new();
    env.init().expect("init");

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");

    let h = conn.get_handles();
    let guard = h.lock().unwrap();
    let odbc = guard
        .get_connection(conn.get_connection_id())
        .expect("odbc");

    let buf = list_tables(odbc, None, None).expect("list_tables");
    drop(guard);
    conn.disconnect().expect("disconnect");

    let dec = BinaryProtocolDecoder::parse(&buf).expect("decode");
    assert!(dec.column_count >= 4, "TABLES has ≥4 columns");
    assert!(dec.row_count >= 1, "at least one table");
}

#[test]
fn test_catalog_list_tables_schema_filter() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }

    let conn_str = get_sqlserver_test_dsn().expect("DSN");
    let env = OdbcEnvironment::new();
    env.init().expect("init");

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");

    let h = conn.get_handles();
    let guard = h.lock().unwrap();
    let odbc = guard
        .get_connection(conn.get_connection_id())
        .expect("odbc");

    let buf = list_tables(odbc, None, Some("INFORMATION_SCHEMA")).expect("list_tables");
    drop(guard);
    conn.disconnect().expect("disconnect");

    let dec = BinaryProtocolDecoder::parse(&buf).expect("decode");
    assert!(dec.column_count >= 4);
}

#[test]
fn test_catalog_list_columns() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }

    let conn_str = get_sqlserver_test_dsn().expect("DSN");
    let env = OdbcEnvironment::new();
    env.init().expect("init");

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");

    let h = conn.get_handles();
    let guard = h.lock().unwrap();
    let odbc = guard
        .get_connection(conn.get_connection_id())
        .expect("odbc");

    // Create a test table to list columns from
    execute_query_with_connection(
        odbc,
        "IF OBJECT_ID('dbo.odbc_catalog_test', 'U') IS NOT NULL DROP TABLE dbo.odbc_catalog_test",
    )
    .ok();
    execute_query_with_connection(
        odbc,
        "CREATE TABLE dbo.odbc_catalog_test (id INT PRIMARY KEY, name VARCHAR(50), age INT)",
    )
    .expect("create table");

    let buf = list_columns(odbc, "dbo.odbc_catalog_test").expect("list_columns");

    // Clean up
    execute_query_with_connection(odbc, "DROP TABLE dbo.odbc_catalog_test").ok();

    drop(guard);
    conn.disconnect().expect("disconnect");

    let dec = BinaryProtocolDecoder::parse(&buf).expect("decode");
    assert!(dec.column_count >= 5, "COLUMNS has ≥5 columns");
    assert_eq!(dec.row_count, 3, "should have 3 columns (id, name, age)");
}

#[test]
fn test_catalog_list_columns_table_only() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }

    let conn_str = get_sqlserver_test_dsn().expect("DSN");
    let env = OdbcEnvironment::new();
    env.init().expect("init");

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");

    let h = conn.get_handles();
    let guard = h.lock().unwrap();
    let odbc = guard
        .get_connection(conn.get_connection_id())
        .expect("odbc");

    let buf = list_columns(odbc, "TABLES").expect("list_columns");
    drop(guard);
    conn.disconnect().expect("disconnect");

    let dec = BinaryProtocolDecoder::parse(&buf).expect("decode");
    assert!(dec.column_count >= 5);
}

#[test]
fn test_catalog_get_type_info() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }

    let conn_str = get_sqlserver_test_dsn().expect("DSN");
    let env = OdbcEnvironment::new();
    env.init().expect("init");

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");

    let h = conn.get_handles();
    let guard = h.lock().unwrap();
    let odbc = guard
        .get_connection(conn.get_connection_id())
        .expect("odbc");

    let buf = get_type_info(odbc).expect("get_type_info");
    drop(guard);
    conn.disconnect().expect("disconnect");

    let dec = BinaryProtocolDecoder::parse(&buf).expect("decode");
    assert!(dec.column_count >= 1, "type_name");
    assert!(dec.row_count >= 1, "at least one type");
}

/// Basic E2E connection tests for SQL Server
/// These tests verify the most fundamental operations: connect, query, disconnect
use odbc_engine::engine::{execute_query_with_connection, OdbcConnection, OdbcEnvironment};
use odbc_engine::protocol::BinaryProtocolDecoder;

mod helpers;
use helpers::e2e::should_run_e2e_tests;
use helpers::env::get_sqlserver_test_dsn;

#[test]
fn test_basic_connection() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing basic connection to SQL Server...");
    println!("Connection string: {}", conn_str);

    // Initialize environment
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    println!("✓ ODBC environment initialized");

    // Connect to database
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Disconnect
    conn.disconnect().expect("Failed to disconnect");
    println!("✓ Disconnected successfully");

    println!("\n✅ Basic connection test PASSED");
}

#[test]
fn test_basic_select_one() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing SELECT 1 query...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Get ODBC connection handle
    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Execute simple query
    let sql = "SELECT 1 AS value";
    println!("Executing: {}", sql);
    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute SELECT 1");
    println!("✓ Query executed successfully");

    drop(handles_guard);

    // Decode result
    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode result");
    println!("✓ Result decoded successfully");

    // Verify result
    assert_eq!(decoded.column_count, 1, "Should have 1 column");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");
    assert!(decoded.rows[0][0].is_some(), "Value should not be NULL");

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    assert_eq!(value, 1, "Value should be 1");
    println!("✓ Result verified: value = {}", value);

    // Disconnect
    conn.disconnect().expect("Failed to disconnect");
    println!("✓ Disconnected successfully");

    println!("\n✅ SELECT 1 test PASSED");
}

#[test]
fn test_multiple_queries_same_connection() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing multiple queries on same connection...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Execute multiple queries
    for i in 1..=3 {
        let handles = conn.get_handles();
        let handles_guard = handles.lock().unwrap();
        let odbc_conn = handles_guard
            .get_connection(conn.get_connection_id())
            .expect("Failed to get ODBC connection handle");

        let sql = format!("SELECT {} AS value", i);
        println!("Executing query {}: {}", i, sql);

        let buffer = execute_query_with_connection(odbc_conn, &sql)
            .unwrap_or_else(|_| panic!("Failed to execute query {}", i));

        drop(handles_guard);

        let decoded = BinaryProtocolDecoder::parse(&buffer)
            .unwrap_or_else(|_| panic!("Failed to decode result {}", i));

        assert_eq!(decoded.column_count, 1);
        assert_eq!(decoded.row_count, 1);

        let bytes = decoded.rows[0][0].as_ref().unwrap();
        let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        assert_eq!(value, i);
        println!("✓ Query {} verified: value = {}", i, value);
    }

    // Disconnect
    conn.disconnect().expect("Failed to disconnect");
    println!("✓ Disconnected successfully");

    println!("\n✅ Multiple queries test PASSED");
}

#[test]
fn test_reconnect() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing reconnect (connect, disconnect, connect again)...");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");

    // First connection
    println!("\n--- First connection ---");
    let handles = env.get_handles();
    let conn1 = OdbcConnection::connect(handles.clone(), &conn_str)
        .expect("Failed to connect (first time)");
    println!("✓ First connection established");

    // Execute query on first connection
    let handles1 = conn1.get_handles();
    let handles_guard = handles1.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn1.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    let buffer = execute_query_with_connection(odbc_conn, "SELECT 1 AS value")
        .expect("Failed to execute query on first connection");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode first result");
    assert_eq!(decoded.row_count, 1);
    println!("✓ First query executed successfully");

    // Disconnect
    conn1
        .disconnect()
        .expect("Failed to disconnect first connection");
    println!("✓ First connection disconnected");

    // Second connection
    println!("\n--- Second connection ---");
    let conn2 =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect (second time)");
    println!("✓ Second connection established");

    // Execute query on second connection
    let handles2 = conn2.get_handles();
    let handles_guard = handles2.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn2.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    let buffer = execute_query_with_connection(odbc_conn, "SELECT 2 AS value")
        .expect("Failed to execute query on second connection");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode second result");
    assert_eq!(decoded.row_count, 1);

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    assert_eq!(value, 2);
    println!("✓ Second query executed successfully: value = {}", value);

    // Disconnect second connection
    conn2
        .disconnect()
        .expect("Failed to disconnect second connection");
    println!("✓ Second connection disconnected");

    println!("\n✅ Reconnect test PASSED");
}

#[test]
fn test_database_info() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing database info queries...");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Query SQL Server version
    println!("\n--- Querying SQL Server version ---");
    let sql = "SELECT @@VERSION AS server_version";
    let buffer =
        execute_query_with_connection(odbc_conn, sql).expect("Failed to query SQL Server version");

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode version result");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let version_bytes = decoded.rows[0][0].as_ref().unwrap();
    let version = String::from_utf8_lossy(version_bytes);
    println!(
        "✓ SQL Server Version: {}",
        version.lines().next().unwrap_or("Unknown")
    );

    // Query database name
    println!("\n--- Querying current database ---");
    let sql = "SELECT DB_NAME() AS database_name";
    let buffer =
        execute_query_with_connection(odbc_conn, sql).expect("Failed to query database name");

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode database result");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let db_bytes = decoded.rows[0][0].as_ref().unwrap();
    let db_name = String::from_utf8_lossy(db_bytes);
    println!("✓ Current Database: {}", db_name);

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("\n✅ Database info test PASSED");
}

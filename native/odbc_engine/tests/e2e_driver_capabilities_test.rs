/// E2E tests for DriverCapabilities with real SQL Server connection
use odbc_engine::engine::core::DriverCapabilities;
use odbc_engine::engine::{OdbcConnection, OdbcEnvironment};

mod helpers;
use helpers::e2e::should_run_e2e_tests;
use helpers::env::get_sqlserver_test_dsn;

#[test]
fn test_driver_capabilities_detect() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing DriverCapabilities::detect...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Get ODBC connection
    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Detect capabilities
    let caps = DriverCapabilities::detect(odbc_conn).expect("Failed to detect driver capabilities");

    println!("✓ Capabilities detected");
    println!(
        "  - supports_prepared_statements: {}",
        caps.supports_prepared_statements
    );
    println!(
        "  - supports_batch_operations: {}",
        caps.supports_batch_operations
    );
    println!("  - supports_streaming: {}", caps.supports_streaming);
    println!("  - max_row_array_size: {}", caps.max_row_array_size);
    println!("  - driver_name: {}", caps.driver_name);
    println!("  - driver_version: {}", caps.driver_version);

    // Verify default values (currently hardcoded)
    assert!(
        caps.supports_prepared_statements,
        "Should support prepared statements"
    );
    assert!(
        caps.supports_batch_operations,
        "Should support batch operations"
    );
    assert!(caps.supports_streaming, "Should support streaming");
    assert_eq!(
        caps.max_row_array_size, 1000,
        "Max row array size should be 1000"
    );
    assert_eq!(
        caps.driver_name, "Unknown",
        "Driver name should be Unknown (not yet implemented)"
    );
    assert_eq!(
        caps.driver_version, "Unknown",
        "Driver version should be Unknown (not yet implemented)"
    );

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("✅ Driver capabilities detect test PASSED");
}

#[test]
fn test_driver_capabilities_detect_multiple_times() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing DriverCapabilities::detect multiple times...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Get ODBC connection
    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Detect capabilities multiple times
    let caps1 =
        DriverCapabilities::detect(odbc_conn).expect("Failed to detect capabilities (first time)");
    let caps2 =
        DriverCapabilities::detect(odbc_conn).expect("Failed to detect capabilities (second time)");
    let caps3 =
        DriverCapabilities::detect(odbc_conn).expect("Failed to detect capabilities (third time)");

    // Verify consistency
    assert_eq!(
        caps1.supports_prepared_statements,
        caps2.supports_prepared_statements
    );
    assert_eq!(
        caps2.supports_prepared_statements,
        caps3.supports_prepared_statements
    );

    assert_eq!(
        caps1.supports_batch_operations,
        caps2.supports_batch_operations
    );
    assert_eq!(
        caps2.supports_batch_operations,
        caps3.supports_batch_operations
    );

    assert_eq!(caps1.supports_streaming, caps2.supports_streaming);
    assert_eq!(caps2.supports_streaming, caps3.supports_streaming);

    assert_eq!(caps1.max_row_array_size, caps2.max_row_array_size);
    assert_eq!(caps2.max_row_array_size, caps3.max_row_array_size);

    assert_eq!(caps1.driver_name, caps2.driver_name);
    assert_eq!(caps2.driver_name, caps3.driver_name);

    assert_eq!(caps1.driver_version, caps2.driver_version);
    assert_eq!(caps2.driver_version, caps3.driver_version);

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("✅ Multiple detections test PASSED");
}

#[test]
fn test_driver_capabilities_clone() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing DriverCapabilities clone...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Get ODBC connection
    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Detect capabilities
    let caps1 = DriverCapabilities::detect(odbc_conn).expect("Failed to detect capabilities");

    // Clone
    let caps2 = caps1.clone();

    // Verify all fields are equal
    assert_eq!(
        caps1.supports_prepared_statements,
        caps2.supports_prepared_statements
    );
    assert_eq!(
        caps1.supports_batch_operations,
        caps2.supports_batch_operations
    );
    assert_eq!(caps1.supports_streaming, caps2.supports_streaming);
    assert_eq!(caps1.max_row_array_size, caps2.max_row_array_size);
    assert_eq!(caps1.driver_name, caps2.driver_name);
    assert_eq!(caps1.driver_version, caps2.driver_version);

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("✅ Clone test PASSED");
}

#[test]
fn test_driver_capabilities_debug() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing DriverCapabilities Debug format...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Get ODBC connection
    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Detect capabilities
    let caps = DriverCapabilities::detect(odbc_conn).expect("Failed to detect capabilities");

    // Format as debug string
    let debug_str = format!("{:?}", caps);
    println!("Debug output: {}", debug_str);

    // Verify debug string contains expected fields
    assert!(
        debug_str.contains("DriverCapabilities"),
        "Should contain struct name"
    );
    assert!(
        debug_str.contains("supports_prepared_statements"),
        "Should contain supports_prepared_statements"
    );
    assert!(
        debug_str.contains("supports_batch_operations"),
        "Should contain supports_batch_operations"
    );
    assert!(
        debug_str.contains("supports_streaming"),
        "Should contain supports_streaming"
    );
    assert!(
        debug_str.contains("max_row_array_size"),
        "Should contain max_row_array_size"
    );
    assert!(
        debug_str.contains("driver_name"),
        "Should contain driver_name"
    );
    assert!(
        debug_str.contains("driver_version"),
        "Should contain driver_version"
    );

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("✅ Debug format test PASSED");
}

#[test]
fn test_driver_capabilities_with_different_connections() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing DriverCapabilities with different connections...");

    // First connection
    let env1 = OdbcEnvironment::new();
    env1.init().expect("Failed to initialize ODBC environment");
    let handles1 = env1.get_handles();
    let conn1 = OdbcConnection::connect(handles1, &conn_str)
        .expect("Failed to connect to SQL Server (first)");

    let conn_handles1 = conn1.get_handles();
    let handles_guard1 = conn_handles1.lock().unwrap();
    let odbc_conn1 = handles_guard1
        .get_connection(conn1.get_connection_id())
        .expect("Failed to get ODBC connection handle (first)");

    let caps1 =
        DriverCapabilities::detect(odbc_conn1).expect("Failed to detect capabilities (first)");

    drop(handles_guard1);
    conn1.disconnect().expect("Failed to disconnect (first)");

    // Second connection
    let env2 = OdbcEnvironment::new();
    env2.init().expect("Failed to initialize ODBC environment");
    let handles2 = env2.get_handles();
    let conn2 = OdbcConnection::connect(handles2, &conn_str)
        .expect("Failed to connect to SQL Server (second)");

    let conn_handles2 = conn2.get_handles();
    let handles_guard2 = conn_handles2.lock().unwrap();
    let odbc_conn2 = handles_guard2
        .get_connection(conn2.get_connection_id())
        .expect("Failed to get ODBC connection handle (second)");

    let caps2 =
        DriverCapabilities::detect(odbc_conn2).expect("Failed to detect capabilities (second)");

    drop(handles_guard2);
    conn2.disconnect().expect("Failed to disconnect (second)");

    // Verify both connections return same capabilities (since currently hardcoded)
    assert_eq!(
        caps1.supports_prepared_statements,
        caps2.supports_prepared_statements
    );
    assert_eq!(
        caps1.supports_batch_operations,
        caps2.supports_batch_operations
    );
    assert_eq!(caps1.supports_streaming, caps2.supports_streaming);
    assert_eq!(caps1.max_row_array_size, caps2.max_row_array_size);
    assert_eq!(caps1.driver_name, caps2.driver_name);
    assert_eq!(caps1.driver_version, caps2.driver_version);

    println!("✅ Different connections test PASSED");
}

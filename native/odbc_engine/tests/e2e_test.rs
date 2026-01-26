use odbc_engine::{
    execute_query_with_connection, BinaryProtocolDecoder, OdbcConnection, OdbcEnvironment,
};

/// Helper to get ODBC_TEST_DSN from environment
fn get_test_dsn() -> Option<String> {
    std::env::var("ODBC_TEST_DSN")
        .ok()
        .filter(|s| !s.is_empty())
}

#[test]
#[ignore]
fn test_e2e_select_5() {
    // Get connection string from environment
    let conn_str: String = match get_test_dsn() {
        Some(dsn) => dsn,
        None => {
            eprintln!("Skipping test: ODBC_TEST_DSN not set");
            return;
        }
    };

    // Initialize environment
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    // Connect to database
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to database");

    // Get the actual ODBC connection
    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Execute query: SELECT 5 AS value
    let sql = "SELECT 5 AS value";
    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    // Drop guard before disconnect
    drop(handles_guard);

    // Decode the binary protocol
    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    // Validate structure
    assert_eq!(decoded.column_count, 1, "Should have exactly 1 column");
    assert_eq!(decoded.row_count, 1, "Should have exactly 1 row");
    assert_eq!(decoded.columns.len(), 1, "Should have 1 column metadata");

    // Validate column metadata
    assert_eq!(
        decoded.columns[0].name, "value",
        "Column name should be 'value'"
    );
    // Note: The actual ODBC type depends on the database driver
    // It could be Integer, BigInt, Decimal, or even Varchar depending on the driver
    // We'll accept any type and just validate the value can be decoded
    println!(
        "Column type: {:?} (driver-specific)",
        decoded.columns[0].odbc_type
    );

    // Validate row data
    assert_eq!(decoded.rows.len(), 1, "Should have 1 row");
    assert_eq!(decoded.rows[0].len(), 1, "Row should have 1 cell");

    let cell_data = decoded.rows[0][0]
        .as_ref()
        .expect("Cell should not be NULL");

    // Decode the integer value (little-endian)
    // The value 5 should be encoded as [5, 0, 0, 0] for i32 or [5, 0, 0, 0, 0, 0, 0, 0] for i64
    let value = if cell_data.len() >= 4 {
        i32::from_le_bytes([cell_data[0], cell_data[1], cell_data[2], cell_data[3]])
    } else if cell_data.len() >= 8 {
        i64::from_le_bytes([
            cell_data[0],
            cell_data[1],
            cell_data[2],
            cell_data[3],
            cell_data[4],
            cell_data[5],
            cell_data[6],
            cell_data[7],
        ]) as i32
    } else {
        // Try to parse as string (some drivers return text)
        String::from_utf8_lossy(cell_data)
            .trim()
            .parse::<i32>()
            .unwrap_or_else(|_| panic!("Could not decode value from buffer: {:?}", cell_data))
    };

    assert_eq!(value, 5, "Query result should be 5, got {}", value);

    println!("✓ SELECT 5 test passed: returned {}", value);

    // Disconnect
    conn.disconnect().expect("Failed to disconnect");
}

#[test]
#[ignore]
fn test_e2e_select_5_multiple_columns() {
    // Get connection string from environment
    let conn_str: String = match get_test_dsn() {
        Some(dsn) => dsn,
        None => {
            eprintln!("Skipping test: ODBC_TEST_DSN not set");
            return;
        }
    };

    // Initialize environment
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    // Connect to database
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to database");

    // Get the actual ODBC connection
    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Execute query: SELECT 5 AS num, 'test' AS text
    let sql = "SELECT 5 AS num, 'test' AS text";
    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    // Drop guard before disconnect
    drop(handles_guard);

    // Decode the binary protocol
    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    // Validate structure
    assert_eq!(decoded.column_count, 2, "Should have exactly 2 columns");
    assert_eq!(decoded.row_count, 1, "Should have exactly 1 row");

    // Validate column metadata
    assert_eq!(
        decoded.columns[0].name, "num",
        "First column name should be 'num'"
    );
    assert_eq!(
        decoded.columns[1].name, "text",
        "Second column name should be 'text'"
    );

    // Validate row data
    assert_eq!(decoded.rows.len(), 1, "Should have 1 row");
    assert_eq!(decoded.rows[0].len(), 2, "Row should have 2 cells");

    // Validate first cell (num = 5)
    let num_data = decoded.rows[0][0]
        .as_ref()
        .expect("First cell should not be NULL");

    let num_value = if num_data.len() >= 4 {
        i32::from_le_bytes([num_data[0], num_data[1], num_data[2], num_data[3]])
    } else {
        String::from_utf8_lossy(num_data)
            .trim()
            .parse::<i32>()
            .unwrap_or_else(|_| panic!("Could not decode num from: {:?}", num_data))
    };

    assert_eq!(num_value, 5, "First column should be 5");

    // Validate second cell (text = 'test')
    let text_data = decoded.rows[0][1]
        .as_ref()
        .expect("Second cell should not be NULL");

    let text_value = String::from_utf8_lossy(text_data);
    assert_eq!(
        text_value, "test",
        "Second column should be 'test', got '{}'",
        text_value
    );

    println!(
        "✓ SELECT 5, 'test' test passed: num={}, text='{}'",
        num_value, text_value
    );

    // Disconnect
    conn.disconnect().expect("Failed to disconnect");
}

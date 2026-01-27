use odbc_engine::{
    execute_query_with_connection, BinaryProtocolDecoder, OdbcConnection, OdbcEnvironment,
};
mod helpers;
use helpers::e2e::{is_database_type, should_run_e2e_tests, DatabaseType};
use helpers::get_sqlserver_test_dsn;

/// Helper to decode integer values from binary data or text
fn decode_integer(data: &[u8]) -> i32 {
    // Try as LE bytes first (4 bytes for i32)
    if data.len() == 4 {
        return i32::from_le_bytes([data[0], data[1], data[2], data[3]]);
    }
    // Try as text (ODBC sometimes returns numbers as text)
    String::from_utf8_lossy(data)
        .trim()
        .parse::<i32>()
        .unwrap_or_else(|_| panic!("Could not decode integer from: {:?}", data))
}

/// Helper to decode bigint values from binary data or text
fn decode_bigint(data: &[u8]) -> i64 {
    // Try as LE bytes first (8 bytes for i64)
    if data.len() == 8 {
        return i64::from_le_bytes([
            data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7],
        ]);
    }
    // Try as text (ODBC sometimes returns numbers as text)
    String::from_utf8_lossy(data)
        .trim()
        .parse::<i64>()
        .unwrap_or_else(|_| panic!("Could not decode bigint from: {:?}", data))
}

/// Helper to decode decimal/float/money values from text or binary
fn decode_decimal(data: &[u8]) -> f64 {
    // DECIMAL, NUMERIC, FLOAT, MONEY are typically returned as text by ODBC drivers
    // Try as text first (most common for these types)
    let text = String::from_utf8_lossy(data).trim().to_string();
    if let Ok(val) = text.parse::<f64>() {
        return val;
    }

    // Fallback: try as LE bytes (8 bytes for f64)
    if data.len() == 8 {
        return f64::from_le_bytes([
            data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7],
        ]);
    }

    // Fallback: try as f32 LE bytes
    if data.len() == 4 {
        return f32::from_le_bytes([data[0], data[1], data[2], data[3]]) as f64;
    }

    panic!("Could not decode decimal from: {:?}", data)
}

#[test]
fn test_e2e_sqlserver_integer_types() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }

    // Skip if not SQL Server (test uses SQL Server specific types)
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let conn_str: String =
        get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Test INT, BIGINT, SMALLINT, TINYINT
    let sql = "SELECT 
        42 AS int_val,
        9223372036854775807 AS bigint_val,
        32767 AS smallint_val,
        255 AS tinyint_val";

    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 4, "Should have 4 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    // Validate INT
    let int_data = decoded.rows[0][0]
        .as_ref()
        .expect("INT column should not be NULL");
    let int_val = decode_integer(int_data);
    assert_eq!(int_val, 42, "INT value should be 42");

    // Validate BIGINT
    let bigint_data = decoded.rows[0][1]
        .as_ref()
        .expect("BIGINT column should not be NULL");
    let bigint_val = decode_bigint(bigint_data);
    assert_eq!(
        bigint_val, 9223372036854775807,
        "BIGINT value should be max i64"
    );

    // Validate SMALLINT
    let smallint_data = decoded.rows[0][2]
        .as_ref()
        .expect("SMALLINT column should not be NULL");
    let smallint_val = decode_integer(smallint_data);
    assert_eq!(smallint_val, 32767, "SMALLINT value should be 32767");

    // Validate TINYINT
    let tinyint_data = decoded.rows[0][3]
        .as_ref()
        .expect("TINYINT column should not be NULL");
    let tinyint_val = decode_integer(tinyint_data);
    assert_eq!(tinyint_val, 255, "TINYINT value should be 255");

    println!("✓ Integer types test passed");

    conn.disconnect().expect("Failed to disconnect");
}

#[test]
fn test_e2e_sqlserver_decimal_types() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }

    // Skip if not SQL Server (test uses SQL Server specific types)
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let conn_str: String =
        get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Test DECIMAL, NUMERIC, FLOAT, REAL
    let sql = "SELECT 
        123.456 AS decimal_val,
        789.012 AS numeric_val,
        3.14159265359 AS float_val,
        2.71828 AS real_val";

    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 4, "Should have 4 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    // Validate DECIMAL (approximate due to floating point)
    let decimal_data = decoded.rows[0][0]
        .as_ref()
        .expect("DECIMAL column should not be NULL");
    let decimal_val = decode_decimal(decimal_data);
    assert!(
        (decimal_val - 123.456).abs() < 0.01,
        "DECIMAL value should be ~123.456"
    );

    println!("✓ Decimal types test passed");

    conn.disconnect().expect("Failed to disconnect");
}

#[test]
fn test_e2e_sqlserver_string_types() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str: String =
        get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Test VARCHAR, NVARCHAR, CHAR, NCHAR
    let sql = "SELECT 
        'Hello World' AS varchar_val,
        N'Unicode Test' AS nvarchar_val,
        'Fixed' AS char_val,
        N'FixedUnicode' AS nchar_val";

    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 4, "Should have 4 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    // Validate VARCHAR
    let varchar_data = decoded.rows[0][0]
        .as_ref()
        .expect("VARCHAR column should not be NULL");
    let varchar_val = String::from_utf8_lossy(varchar_data).trim().to_string();
    assert_eq!(
        varchar_val, "Hello World",
        "VARCHAR value should be 'Hello World'"
    );

    // Validate NVARCHAR (may be UTF-16 or UTF-8 depending on driver)
    let nvarchar_data = decoded.rows[0][1]
        .as_ref()
        .expect("NVARCHAR column should not be NULL");
    let nvarchar_val = String::from_utf8_lossy(nvarchar_data).trim().to_string();
    assert!(
        nvarchar_val.contains("Unicode") || nvarchar_val.contains("Test"),
        "NVARCHAR should contain 'Unicode' or 'Test'"
    );

    println!("✓ String types test passed");

    conn.disconnect().expect("Failed to disconnect");
}

#[test]
fn test_e2e_sqlserver_date_time_types() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }

    // Skip if not SQL Server (test uses SQL Server specific types: DATETIME2)
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let conn_str: String =
        get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Test DATE, DATETIME, DATETIME2, TIME
    let sql = "SELECT 
        CAST('2024-01-15' AS DATE) AS date_val,
        CAST('2024-01-15 14:30:00' AS DATETIME) AS datetime_val,
        CAST('2024-01-15 14:30:00.123' AS DATETIME2) AS datetime2_val,
        CAST('14:30:00' AS TIME) AS time_val";

    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 4, "Should have 4 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    // All date/time columns should have data (not NULL)
    for i in 0..4 {
        assert!(
            decoded.rows[0][i].is_some(),
            "Date/time column {} should not be NULL",
            i
        );
    }

    println!("✓ Date/time types test passed");

    conn.disconnect().expect("Failed to disconnect");
}

#[test]
fn test_e2e_sqlserver_null_values() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str: String =
        get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Test NULL values in different types
    let sql = "SELECT 
        NULL AS null_int,
        NULL AS null_string,
        NULL AS null_decimal,
        NULL AS null_date,
        42 AS not_null_val";

    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 5, "Should have 5 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    // First 4 columns should be NULL
    for i in 0..4 {
        assert!(decoded.rows[0][i].is_none(), "Column {} should be NULL", i);
    }

    // Last column should not be NULL
    assert!(
        decoded.rows[0][4].is_some(),
        "Last column should not be NULL"
    );

    let not_null_data = decoded.rows[0][4]
        .as_ref()
        .expect("Last column should not be NULL");
    let not_null_val = decode_integer(not_null_data);
    assert_eq!(not_null_val, 42, "Non-NULL value should be 42");

    println!("✓ NULL values test passed");

    conn.disconnect().expect("Failed to disconnect");
}

#[test]
fn test_e2e_sqlserver_multiple_rows() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str: String =
        get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Test multiple rows
    let sql = "SELECT 
        number AS id,
        number * 2 AS doubled
    FROM (
        SELECT 1 AS number UNION ALL
        SELECT 2 UNION ALL
        SELECT 3 UNION ALL
        SELECT 4 UNION ALL
        SELECT 5
    ) AS numbers
    ORDER BY id";

    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 2, "Should have 2 columns");
    assert_eq!(decoded.row_count, 5, "Should have 5 rows");

    // Validate each row
    for i in 0..5 {
        let id_data = decoded.rows[i][0]
            .as_ref()
            .expect("ID column should not be NULL");
        let id_val = decode_integer(id_data);
        assert_eq!(id_val, (i + 1) as i32, "ID should be {}", i + 1);

        let doubled_data = decoded.rows[i][1]
            .as_ref()
            .expect("Doubled column should not be NULL");
        let doubled_val = decode_integer(doubled_data);
        assert_eq!(
            doubled_val,
            ((i + 1) * 2) as i32,
            "Doubled should be {}",
            (i + 1) * 2
        );
    }

    println!("✓ Multiple rows test passed");

    conn.disconnect().expect("Failed to disconnect");
}

#[test]
fn test_e2e_sqlserver_aggregate_functions() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }

    // Skip if not SQL Server (test uses SQL Server specific syntax)
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let conn_str: String =
        get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Test aggregate functions
    let sql = "SELECT 
        COUNT(*) AS count_val,
        SUM(number) AS sum_val,
        AVG(number) AS avg_val,
        MIN(number) AS min_val,
        MAX(number) AS max_val
    FROM (
        SELECT 10 AS number UNION ALL
        SELECT 20 UNION ALL
        SELECT 30 UNION ALL
        SELECT 40 UNION ALL
        SELECT 50
    ) AS numbers";

    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 5, "Should have 5 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    // Validate COUNT
    let count_data = decoded.rows[0][0]
        .as_ref()
        .expect("COUNT column should not be NULL");
    let count_val = decode_integer(count_data);
    assert_eq!(count_val, 5, "COUNT should be 5");

    // Validate SUM
    let sum_data = decoded.rows[0][1]
        .as_ref()
        .expect("SUM column should not be NULL");
    let sum_val = decode_integer(sum_data);
    assert_eq!(sum_val, 150, "SUM should be 150");

    // Validate AVG (SQL Server returns INT for AVG of INTs)
    let avg_data = decoded.rows[0][2]
        .as_ref()
        .expect("AVG column should not be NULL");
    let avg_val = decode_integer(avg_data);
    assert_eq!(avg_val, 30, "AVG should be 30");

    // Validate MIN
    let min_data = decoded.rows[0][3]
        .as_ref()
        .expect("MIN column should not be NULL");
    let min_val = decode_integer(min_data);
    assert_eq!(min_val, 10, "MIN should be 10");

    // Validate MAX
    let max_data = decoded.rows[0][4]
        .as_ref()
        .expect("MAX column should not be NULL");
    let max_val = decode_integer(max_data);
    assert_eq!(max_val, 50, "MAX should be 50");

    println!("✓ Aggregate functions test passed");

    conn.disconnect().expect("Failed to disconnect");
}

#[test]
fn test_e2e_sqlserver_complex_query() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }

    // Skip if not SQL Server (test uses SQL Server specific syntax)
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let conn_str: String =
        get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Test complex query with JOIN, WHERE, ORDER BY
    let sql = "SELECT 
        a.id,
        a.value * 2 AS doubled,
        CASE 
            WHEN a.value > 2 THEN 'High'
            ELSE 'Low'
        END AS category
    FROM (
        SELECT 1 AS id, 1 AS value UNION ALL
        SELECT 2, 2 UNION ALL
        SELECT 3, 3 UNION ALL
        SELECT 4, 4 UNION ALL
        SELECT 5, 5
    ) AS a
    WHERE a.value >= 2
    ORDER BY a.id";

    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 3, "Should have 3 columns");
    assert_eq!(
        decoded.row_count, 4,
        "Should have 4 rows (filtered WHERE value >= 2)"
    );

    // Validate first row (id=2, value=2, category='Low')
    let id_data = decoded.rows[0][0]
        .as_ref()
        .expect("ID column should not be NULL");
    let id_val = decode_integer(id_data);
    assert_eq!(id_val, 2, "First row ID should be 2");

    let doubled_data = decoded.rows[0][1]
        .as_ref()
        .expect("Doubled column should not be NULL");
    let doubled_val = decode_integer(doubled_data);
    assert_eq!(doubled_val, 4, "First row doubled should be 4");

    let category_data = decoded.rows[0][2]
        .as_ref()
        .expect("Category column should not be NULL");
    let category_val = String::from_utf8_lossy(category_data).trim().to_string();
    assert_eq!(
        category_val, "Low",
        "Category should be 'Low' for value=2 (not > 2)"
    );

    // Validate second row (id=3, value=3, category='High')
    let id_data_2 = decoded.rows[1][0]
        .as_ref()
        .expect("ID column should not be NULL");
    let id_val_2 = decode_integer(id_data_2);
    assert_eq!(id_val_2, 3, "Second row ID should be 3");

    let category_data_2 = decoded.rows[1][2]
        .as_ref()
        .expect("Category column should not be NULL");
    let category_val_2 = String::from_utf8_lossy(category_data_2).trim().to_string();
    assert_eq!(
        category_val_2, "High",
        "Category should be 'High' for value=3 (which is > 2)"
    );

    println!("✓ Complex query test passed");

    conn.disconnect().expect("Failed to disconnect");
}

#[test]
fn test_e2e_sqlserver_binary_types() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }

    // Skip if not SQL Server (test uses SQL Server specific types: VARBINARY(MAX))
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let conn_str: String =
        get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Test BINARY, VARBINARY, and IMAGE types
    // Note: IMAGE is deprecated but still supported in SQL Server
    // We'll use CONVERT to create binary data from hex strings
    let sql = "SELECT 
        CAST(0x48656C6C6F AS BINARY(5)) AS binary_val,
        CAST(0x576F726C64 AS VARBINARY(5)) AS varbinary_val,
        CAST(0x54657374496D616765 AS VARBINARY(MAX)) AS image_val";

    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 3, "Should have 3 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    // Validate BINARY (fixed size)
    let binary_data = decoded.rows[0][0]
        .as_ref()
        .expect("BINARY column should not be NULL");
    assert_eq!(binary_data.len(), 5, "BINARY should have 5 bytes");
    // 0x48656C6C6F = "Hello" in ASCII
    assert_eq!(binary_data, b"Hello", "BINARY value should be 'Hello'");

    // Validate VARBINARY (variable size)
    let varbinary_data = decoded.rows[0][1]
        .as_ref()
        .expect("VARBINARY column should not be NULL");
    assert_eq!(varbinary_data.len(), 5, "VARBINARY should have 5 bytes");
    // 0x576F726C64 = "World" in ASCII
    assert_eq!(
        varbinary_data, b"World",
        "VARBINARY value should be 'World'"
    );

    // Validate IMAGE/VARBINARY(MAX) (large binary)
    let image_data = decoded.rows[0][2]
        .as_ref()
        .expect("IMAGE/VARBINARY(MAX) column should not be NULL");
    assert_eq!(image_data.len(), 9, "IMAGE should have 9 bytes");
    // 0x54657374496D616765 = "TestImage" in ASCII
    assert_eq!(
        image_data, b"TestImage",
        "IMAGE value should be 'TestImage'"
    );

    println!("✓ Binary types test passed");

    conn.disconnect().expect("Failed to disconnect");
}

#[test]
fn test_e2e_sqlserver_binary_with_null() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str: String =
        get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Test NULL values in binary types
    let sql = "SELECT 
        NULL AS null_binary,
        CAST(0x48656C6C6F AS BINARY(5)) AS not_null_binary";

    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 2, "Should have 2 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    // First column should be NULL
    assert!(decoded.rows[0][0].is_none(), "First column should be NULL");

    // Second column should not be NULL
    let binary_data = decoded.rows[0][1]
        .as_ref()
        .expect("Second column should not be NULL");
    assert_eq!(
        binary_data, b"Hello",
        "Non-NULL binary value should be 'Hello'"
    );

    println!("✓ Binary with NULL test passed");

    conn.disconnect().expect("Failed to disconnect");
}

#[test]
fn test_e2e_sqlserver_bit_and_money_types() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }

    // Skip if not SQL Server (test uses SQL Server specific types: BIT, MONEY)
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let conn_str: String =
        get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Test BIT and MONEY types
    let sql = "SELECT 
        CAST(1 AS BIT) AS bit_true,
        CAST(0 AS BIT) AS bit_false,
        CAST(1234.5678 AS MONEY) AS money_val,
        CAST(-9876.5432 AS MONEY) AS money_negative";

    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 4, "Should have 4 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    // Validate BIT (true = 1)
    let bit_true_data = decoded.rows[0][0]
        .as_ref()
        .expect("BIT (true) column should not be NULL");
    let bit_true_val = decode_integer(bit_true_data);
    assert_eq!(bit_true_val, 1, "BIT (true) value should be 1");

    // Validate BIT (false = 0)
    let bit_false_data = decoded.rows[0][1]
        .as_ref()
        .expect("BIT (false) column should not be NULL");
    let bit_false_val = decode_integer(bit_false_data);
    assert_eq!(bit_false_val, 0, "BIT (false) value should be 0");

    // Validate MONEY (positive)
    let money_data = decoded.rows[0][2]
        .as_ref()
        .expect("MONEY column should not be NULL");
    let money_val = decode_decimal(money_data);
    // MONEY has 4 decimal places, so we check with tolerance
    assert!(
        (money_val - 1234.5678).abs() < 0.0001,
        "MONEY value should be ~1234.5678, got {}",
        money_val
    );

    // Validate MONEY (negative)
    let money_negative_data = decoded.rows[0][3]
        .as_ref()
        .expect("MONEY (negative) column should not be NULL");
    let money_negative_val = decode_decimal(money_negative_data);
    assert!(
        (money_negative_val - (-9876.5432)).abs() < 0.0001,
        "MONEY (negative) value should be ~-9876.5432, got {}",
        money_negative_val
    );

    println!("✓ BIT and MONEY types test passed");

    conn.disconnect().expect("Failed to disconnect");
}

#[test]
fn test_e2e_sqlserver_text_type() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }

    // Skip if not SQL Server (test uses SQL Server specific types: NVARCHAR(MAX))
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let conn_str: String =
        get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize environment");

    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection");

    // Test TEXT type (legacy type, deprecated but still supported)
    // Note: TEXT is deprecated, but we test it for compatibility
    // Modern alternative is VARCHAR(MAX) or NVARCHAR(MAX)
    let sql = "SELECT 
        CAST('This is a TEXT type test with some content' AS TEXT) AS text_val,
        CAST('Large text content for TEXT type validation' AS VARCHAR(MAX)) AS varchar_max_val";

    let buffer = execute_query_with_connection(odbc_conn, sql).expect("Failed to execute query");

    drop(handles_guard);

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 2, "Should have 2 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    // Validate TEXT (may be returned as VARCHAR depending on driver)
    let text_data = decoded.rows[0][0]
        .as_ref()
        .expect("TEXT column should not be NULL");
    let text_val = String::from_utf8_lossy(text_data).trim().to_string();
    assert!(
        text_val.contains("TEXT type test") || text_val.contains("content"),
        "TEXT value should contain 'TEXT type test' or 'content', got: {}",
        text_val
    );

    // Validate VARCHAR(MAX) (modern alternative to TEXT)
    let varchar_max_data = decoded.rows[0][1]
        .as_ref()
        .expect("VARCHAR(MAX) column should not be NULL");
    let varchar_max_val = String::from_utf8_lossy(varchar_max_data).trim().to_string();
    assert!(
        varchar_max_val.contains("Large text") || varchar_max_val.contains("TEXT type"),
        "VARCHAR(MAX) value should contain 'Large text' or 'TEXT type', got: {}",
        varchar_max_val
    );

    println!("✓ TEXT type test passed");

    conn.disconnect().expect("Failed to disconnect");
}

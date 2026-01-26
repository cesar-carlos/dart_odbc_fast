use odbc_engine::engine::{execute_query_with_connection, OdbcConnection, OdbcEnvironment};
use odbc_engine::protocol::{BinaryProtocolDecoder, DecodedResult};

mod helpers;
use helpers::e2e::should_run_e2e_tests;
use helpers::env::get_sqlserver_test_dsn;

/// Helper function to execute a query and return decoded results
fn execute_and_decode(sql: &str) -> Result<DecodedResult, Box<dyn std::error::Error>> {
    let conn_str = get_sqlserver_test_dsn()
        .expect("Failed to build SQL Server connection string. Check environment variables.");

    let env = OdbcEnvironment::new();
    env.init()?;

    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str)?;

    let handles = conn.get_handles();
    let handles_guard = handles.lock().unwrap();
    let odbc_conn = handles_guard.get_connection(conn.get_connection_id())?;

    let buffer = execute_query_with_connection(odbc_conn, sql)?;

    drop(handles_guard);
    conn.disconnect()?;

    let decoded = BinaryProtocolDecoder::parse(&buffer)?;
    Ok(decoded)
}

#[test]
fn test_read_cell_integer_positive() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT 42 AS value").expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1, "Should have 1 column");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");
    assert!(decoded.rows[0][0].is_some(), "Value should not be NULL");

    // Verify the value
    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    assert_eq!(value, 42, "Integer value should be 42");
}

#[test]
fn test_read_cell_integer_negative() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT -42 AS value").expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    assert_eq!(value, -42, "Integer value should be -42");
}

#[test]
fn test_read_cell_integer_zero() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT 0 AS value").expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    assert_eq!(value, 0, "Integer value should be 0");
}

#[test]
fn test_read_cell_integer_max() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded =
        execute_and_decode("SELECT 2147483647 AS value").expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    assert_eq!(value, i32::MAX, "Integer value should be i32::MAX");
}

#[test]
fn test_read_cell_integer_min() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT CAST(-2147483648 AS INTEGER) AS value")
        .expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    assert_eq!(value, i32::MIN, "Integer value should be i32::MIN");
}

#[test]
fn test_read_cell_bigint_positive() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT CAST(9223372036854775807 AS BIGINT) AS value")
        .expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let value = i64::from_le_bytes([
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
    ]);
    assert_eq!(value, i64::MAX, "BigInt value should be i64::MAX");
}

#[test]
fn test_read_cell_bigint_negative() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT CAST(-9223372036854775808 AS BIGINT) AS value")
        .expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let value = i64::from_le_bytes([
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
    ]);
    assert_eq!(value, i64::MIN, "BigInt value should be i64::MIN");
}

#[test]
fn test_read_cell_bigint_zero() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded =
        execute_and_decode("SELECT CAST(0 AS BIGINT) AS value").expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let value = i64::from_le_bytes([
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
    ]);
    assert_eq!(value, 0, "BigInt value should be 0");
}

#[test]
fn test_read_cell_text_simple() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT 'hello' AS value").expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let text = String::from_utf8_lossy(bytes);
    assert_eq!(text, "hello", "Text value should be 'hello'");
}

#[test]
fn test_read_cell_text_empty() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT '' AS value").expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    assert_eq!(bytes.len(), 0, "Empty text should have 0 bytes");
}

#[test]
fn test_read_cell_text_unicode() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded =
        execute_and_decode("SELECT N'你好世界' AS value").expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let text = String::from_utf8_lossy(bytes);
    // Note: Unicode preservation depends on ODBC driver configuration
    // We just verify that some text was returned
    assert!(!text.is_empty(), "Unicode text should return some value");
    assert_eq!(text.chars().count(), 4, "Should have 4 characters");
}

#[test]
fn test_read_cell_text_special_chars() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded =
        execute_and_decode("SELECT 'test\nline\ttab' AS value").expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let text = String::from_utf8_lossy(bytes);
    assert!(text.contains("test"), "Should contain 'test'");
    assert!(text.contains("line"), "Should contain 'line'");
    assert!(text.contains("tab"), "Should contain 'tab'");
}

#[test]
fn test_read_cell_text_long() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let long_text = "a".repeat(1000);
    let sql = format!("SELECT '{}' AS value", long_text);
    let decoded = execute_and_decode(&sql).expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    assert_eq!(bytes.len(), 1000, "Long text should have 1000 bytes");
}

#[test]
fn test_read_cell_null() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT NULL AS value").expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1, "Should have 1 column");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");
    assert!(decoded.rows[0][0].is_none(), "NULL value should be None");
}

#[test]
fn test_read_cell_binary_simple() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT CAST(0x0102030405 AS VARBINARY(10)) AS value")
        .expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    assert_eq!(
        bytes,
        &[0x01, 0x02, 0x03, 0x04, 0x05],
        "Binary data should match"
    );
}

#[test]
fn test_read_cell_binary_empty() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT CAST('' AS VARBINARY(10)) AS value")
        .expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    assert_eq!(bytes.len(), 0, "Empty binary should have 0 bytes");
}

#[test]
fn test_read_cell_binary_large() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    // Create a 100-byte binary value
    let hex = (0..100)
        .map(|i| format!("{:02X}", i % 256))
        .collect::<Vec<_>>()
        .join("");
    let sql = format!("SELECT CAST(0x{} AS VARBINARY(100)) AS value", hex);
    let decoded = execute_and_decode(&sql).expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    assert_eq!(bytes.len(), 100, "Large binary should have 100 bytes");
}

#[test]
fn test_read_cell_multiple_columns() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT 42 AS int_col, 'text' AS text_col, NULL AS null_col")
        .expect("Failed to execute query");

    assert_eq!(decoded.column_count, 3, "Should have 3 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    // Verify integer column
    assert!(decoded.rows[0][0].is_some(), "int_col should not be NULL");

    // Verify text column
    assert!(decoded.rows[0][1].is_some(), "text_col should not be NULL");
    let text_bytes = decoded.rows[0][1].as_ref().unwrap();
    let text = String::from_utf8_lossy(text_bytes);
    assert_eq!(text, "text", "text_col should be 'text'");

    // Verify NULL column
    assert!(decoded.rows[0][2].is_none(), "null_col should be NULL");
}

#[test]
fn test_read_cell_multiple_rows() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode(
        "SELECT 1 AS value UNION ALL SELECT 2 UNION ALL SELECT 3 ORDER BY value",
    )
    .expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1, "Should have 1 column");
    assert_eq!(decoded.row_count, 3, "Should have 3 rows");

    // Verify each row
    for (i, row) in decoded.rows.iter().enumerate() {
        assert!(row[0].is_some(), "Row {} should not be NULL", i + 1);
        let bytes = row[0].as_ref().unwrap();
        let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        assert_eq!(
            value,
            (i + 1) as i32,
            "Row {} should have value {}",
            i + 1,
            i + 1
        );
    }
}

#[test]
fn test_read_cell_mixed_types() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode(
        "SELECT 
            CAST(42 AS INT) AS int_val,
            CAST(9223372036854775807 AS BIGINT) AS bigint_val,
            CAST('text' AS VARCHAR(10)) AS text_val,
            CAST(0x0102 AS VARBINARY(10)) AS binary_val,
            NULL AS null_val",
    )
    .expect("Failed to execute query");

    assert_eq!(decoded.column_count, 5, "Should have 5 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    // Verify each column type
    assert!(decoded.rows[0][0].is_some(), "int_val should not be NULL");
    assert!(
        decoded.rows[0][1].is_some(),
        "bigint_val should not be NULL"
    );
    assert!(decoded.rows[0][2].is_some(), "text_val should not be NULL");
    assert!(
        decoded.rows[0][3].is_some(),
        "binary_val should not be NULL"
    );
    assert!(decoded.rows[0][4].is_none(), "null_val should be NULL");
}

#[test]
fn test_read_cell_edge_case_whitespace() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT '  42  ' AS value").expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let text = String::from_utf8_lossy(bytes);
    assert_eq!(text, "  42  ", "Whitespace should be preserved");
}

#[test]
fn test_read_cell_edge_case_numeric_string() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded = execute_and_decode("SELECT '12345' AS value").expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some());

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let text = String::from_utf8_lossy(bytes);
    assert_eq!(text, "12345", "Numeric string should be preserved as text");
}

#[test]
fn test_read_cell_edge_case_boolean_as_int() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let decoded =
        execute_and_decode("SELECT CAST(1 AS BIT) AS value").expect("Failed to execute query");

    assert_eq!(decoded.column_count, 1);
    assert_eq!(decoded.row_count, 1);
    assert!(decoded.rows[0][0].is_some(), "BIT value should not be NULL");
}

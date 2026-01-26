use odbc_engine::{
    decode_multi, engine::core::ExecutionEngine, BinaryProtocolDecoder, MultiResultItem,
    OdbcConnection, OdbcEnvironment, ParamValue,
};
mod helpers;
use helpers::e2e::should_run_e2e_tests;
use helpers::get_sqlserver_test_dsn;

/// Helper to decode integer values from binary data
fn decode_integer(data: &[u8]) -> i32 {
    if data.len() >= 4 {
        i32::from_le_bytes([data[0], data[1], data[2], data[3]])
    } else if data.len() >= 8 {
        i64::from_le_bytes([
            data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7],
        ]) as i32
    } else {
        String::from_utf8_lossy(data)
            .trim()
            .parse::<i32>()
            .unwrap_or_else(|_| panic!("Could not decode integer from: {:?}", data))
    }
}

/// Helper to decode string values from binary data
fn decode_string(data: &[u8]) -> String {
    String::from_utf8_lossy(data).trim().to_string()
}

#[test]
fn test_execution_engine_basic_query() {
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let sql = "SELECT 42 AS value, 'Hello' AS msg";
    let buffer = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 2, "Should have 2 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");
    assert_eq!(decoded.columns[0].name, "value");
    assert_eq!(decoded.columns[1].name, "msg");

    let value_data = decoded.rows[0][0]
        .as_ref()
        .expect("value column should not be NULL");
    let value = decode_integer(value_data);
    assert_eq!(value, 42, "value should be 42");

    let message_data = decoded.rows[0][1]
        .as_ref()
        .expect("msg column should not be NULL");
    let message = decode_string(message_data);
    assert_eq!(message, "Hello", "msg should be 'Hello'");

    println!("✓ Basic query test passed");
}

#[test]
fn test_execution_engine_prepared_cache() {
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

    let engine = ExecutionEngine::new(10);
    engine.set_connection_string(&conn_str);

    let sql = "SELECT 1 AS value";

    let buffer1 = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    let buffer2 = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    let decoded1 = BinaryProtocolDecoder::parse(&buffer1).expect("Failed to decode first result");
    let decoded2 = BinaryProtocolDecoder::parse(&buffer2).expect("Failed to decode second result");

    assert_eq!(decoded1.row_count, decoded2.row_count);
    assert_eq!(decoded1.column_count, decoded2.column_count);

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("✓ Prepared cache test passed");
}

#[test]
fn test_execution_engine_plugin_optimization() {
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let sql = "SELECT TOP 10 * FROM (SELECT 1 AS id UNION ALL SELECT 2 UNION ALL SELECT 3) AS t";
    let buffer = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 1, "Should have 1 column");
    assert!(decoded.row_count <= 10, "Should have at most 10 rows");

    println!("✓ Plugin optimization test passed");
}

#[test]
fn test_execution_engine_row_based_encoding() {
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let sql = "SELECT 1 AS col1, 2 AS col2, 3 AS col3";
    let buffer = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 3, "Should have 3 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    println!("✓ Row-based encoding test passed");
}

#[test]
fn test_execution_engine_columnar_encoding() {
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

    let engine = ExecutionEngine::with_columnar(100, false);
    engine.set_connection_string(&conn_str);

    let sql = "SELECT 1 AS col1, 2 AS col2, 3 AS col3";
    let buffer = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    // Columnar encoding uses version 2, which BinaryProtocolDecoder doesn't support
    // Instead, validate the buffer structure directly
    assert!(!buffer.is_empty(), "Buffer should not be empty");
    assert!(
        buffer.len() >= 19,
        "Buffer should have at least header size (19 bytes)"
    );

    // Validate magic number (first 4 bytes)
    let magic = u32::from_le_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]);
    assert_eq!(magic, 0x4F444243, "Magic number should be 0x4F444243");

    // Validate version (bytes 4-5) should be 2 for columnar
    let version = u16::from_le_bytes([buffer[4], buffer[5]]);
    assert_eq!(version, 2, "Version should be 2 for columnar encoding");

    println!("✓ Columnar encoding test passed");
}

#[test]
fn test_execution_engine_columnar_with_compression() {
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

    let engine = ExecutionEngine::with_columnar(100, true);
    engine.set_connection_string(&conn_str);

    let sql = "SELECT 1 AS col1, 2 AS col2, 3 AS col3";
    let buffer = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    // Columnar encoding uses version 2, which BinaryProtocolDecoder doesn't support
    // Instead, validate the buffer structure directly
    assert!(!buffer.is_empty(), "Buffer should not be empty");
    assert!(
        buffer.len() >= 19,
        "Buffer should have at least header size (19 bytes)"
    );

    // Validate magic number (first 4 bytes)
    let magic = u32::from_le_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]);
    assert_eq!(magic, 0x4F444243, "Magic number should be 0x4F444243");

    // Validate version (bytes 4-5) should be 2 for columnar
    let version = u16::from_le_bytes([buffer[4], buffer[5]]);
    assert_eq!(version, 2, "Version should be 2 for columnar encoding");

    // Validate compression flag (byte 14) should be 1 when compression is enabled
    // Header structure: magic(4) + version(2) + flags(2) + col_count(2) + row_count(4) + compression(1) = 15 bytes
    let compression_flag = buffer[14];
    assert_eq!(
        compression_flag, 1,
        "Compression flag should be 1 when enabled"
    );

    println!("✓ Columnar encoding with compression test passed");
}

#[test]
fn test_execution_engine_metrics_recording() {
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let metrics = engine.get_metrics();
    let initial_query_metrics = metrics.get_query_metrics();
    let initial_query_count = initial_query_metrics.query_count;

    let sql = "SELECT 1 AS value";
    let _buffer = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    let query_metrics_after = metrics.get_query_metrics();
    assert_eq!(
        query_metrics_after.query_count,
        initial_query_count + 1,
        "Query count should increase by 1"
    );
    assert!(
        query_metrics_after.total_latency > initial_query_metrics.total_latency,
        "Total latency should increase"
    );

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("✓ Metrics recording test passed");
}

#[test]
fn test_execution_engine_tracing() {
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let tracer = engine.get_tracer();
    let initial_span_id = tracer.start_span("test".to_string());
    let _finished_span = tracer.finish_span(initial_span_id);

    let sql = "SELECT 1 AS value";
    let _buffer = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("✓ Tracing test passed");
}

#[test]
fn test_execution_engine_multiple_rows() {
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let sql = "SELECT 1 AS id UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 ORDER BY id";
    let buffer = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 1, "Should have 1 column");
    assert_eq!(decoded.row_count, 5, "Should have 5 rows");

    for (idx, row) in decoded.rows.iter().enumerate() {
        let id_data = row[0]
            .as_ref()
            .unwrap_or_else(|| panic!("Row {} id should not be NULL", idx));
        let id = decode_integer(id_data);
        assert_eq!(id, (idx + 1) as i32, "Row {} id should be {}", idx, idx + 1);
    }

    println!("✓ Multiple rows test passed");
}

#[test]
fn test_execution_engine_null_values() {
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let sql = "SELECT NULL AS null_col, 42 AS not_null_col";
    let buffer = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 2, "Should have 2 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    assert!(decoded.rows[0][0].is_none(), "First column should be NULL");
    assert!(
        decoded.rows[0][1].is_some(),
        "Second column should not be NULL"
    );

    let not_null_data = decoded.rows[0][1]
        .as_ref()
        .expect("not_null_col should not be NULL");
    let value = decode_integer(not_null_data);
    assert_eq!(value, 42, "not_null_col should be 42");

    println!("✓ NULL values test passed");
}

#[test]
fn test_execution_engine_empty_result_set() {
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let sql = "SELECT 1 AS value WHERE 1 = 0";
    let buffer = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 1, "Should have 1 column");
    assert_eq!(decoded.row_count, 0, "Should have 0 rows");

    println!("✓ Empty result set test passed");
}

#[test]
fn test_execution_engine_mixed_data_types() {
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let sql = "SELECT 
        42 AS int_val,
        9223372036854775807 AS bigint_val,
        'Hello World' AS varchar_val,
        CAST(123.456 AS DECIMAL(10,3)) AS decimal_val,
        CAST(1 AS BIT) AS bit_val";

    let buffer = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 5, "Should have 5 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    assert_eq!(decoded.columns[0].name, "int_val");
    assert_eq!(decoded.columns[1].name, "bigint_val");
    assert_eq!(decoded.columns[2].name, "varchar_val");
    assert_eq!(decoded.columns[3].name, "decimal_val");
    assert_eq!(decoded.columns[4].name, "bit_val");

    println!("✓ Mixed data types test passed");
}

#[test]
fn test_execution_engine_invalid_sql_returns_error() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let invalid_sql = "SELECT * FROM nonexistent_table_xyz_12345";
    let result = engine.execute_query(odbc_conn, invalid_sql);

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    assert!(result.is_err(), "Invalid SQL should return Err");
    println!("✓ Invalid SQL returns error test passed");
}

#[test]
fn test_exec_query_with_params_integer() {
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let params = vec![ParamValue::Integer(42)];
    let sql = "SELECT ? AS value";
    let buffer = engine
        .execute_query_with_params(odbc_conn, sql, &params)
        .expect("Failed to execute parameterized query");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 1, "Should have 1 column");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    let value_data = decoded.rows[0][0]
        .as_ref()
        .expect("value column should not be NULL");
    let value = decode_integer(value_data);
    assert_eq!(value, 42, "value should be 42");

    println!("✓ Exec query with params (integer) test passed");
}

#[test]
fn test_exec_query_with_params_null() {
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let params = vec![ParamValue::Null];
    let sql = "SELECT ? AS x";
    let result = engine.execute_query_with_params(odbc_conn, sql, &params);

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    assert!(
        result.is_err(),
        "NULL parameters should return error (not supported yet)"
    );
    println!("✓ Exec query with params (null) returns error test passed");
}

#[test]
fn test_exec_query_with_params_mixed_types() {
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let params = vec![
        ParamValue::Integer(1),
        ParamValue::String("hello".to_string()),
        ParamValue::Decimal("3.14".to_string()),
    ];
    let sql = "SELECT ? AS a, ? AS b, ? AS c";
    let buffer = engine
        .execute_query_with_params(odbc_conn, sql, &params)
        .expect("Failed to execute parameterized query");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode binary protocol");

    assert_eq!(decoded.column_count, 3, "Should have 3 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    let a_data = decoded.rows[0][0]
        .as_ref()
        .expect("a should not be NULL");
    assert_eq!(decode_integer(a_data), 1);

    let b_data = decoded.rows[0][1]
        .as_ref()
        .expect("b should not be NULL");
    assert_eq!(decode_string(b_data), "hello");

    let c_data = decoded.rows[0][2]
        .as_ref()
        .expect("c should not be NULL");
    let c_str = decode_string(c_data);
    assert!(
        c_str.starts_with("3.14"),
        "decimal c should start with 3.14, got {}",
        c_str
    );

    println!("✓ Exec query with params (mixed types) test passed");
}

#[test]
fn test_execute_multi_result_single_select() {
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string(&conn_str);

    let sql = "SELECT 1 AS value";
    let buffer = engine
        .execute_multi_result(odbc_conn, sql)
        .expect("Failed to execute multi-result");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    let items = decode_multi(&buffer).expect("Failed to decode multi-result");
    assert_eq!(items.len(), 1, "Should have 1 multi-result item");

    match &items[0] {
        MultiResultItem::ResultSet(ref enc) => {
            let decoded = BinaryProtocolDecoder::parse(enc).expect("Failed to decode result set");
            assert_eq!(decoded.column_count, 1);
            assert_eq!(decoded.row_count, 1);
            let v = decoded.rows[0][0].as_ref().expect("value not null");
            assert_eq!(decode_integer(v), 1);
        }
        MultiResultItem::RowCount(_) => panic!("Expected ResultSet, got RowCount"),
    }

    println!("✓ Execute multi-result (single SELECT) test passed");
}

#[test]
fn test_execution_engine_execute_query_no_plugin_uses_raw_sql() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
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

    let engine = ExecutionEngine::new(100);
    engine.set_connection_string("Driver={UnknownDriver};");
    let sql = "SELECT 1 AS value";
    let buffer = engine
        .execute_query(odbc_conn, sql)
        .expect("Failed to execute query");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    let decoded = BinaryProtocolDecoder::parse(&buffer).expect("Failed to decode");
    assert_eq!(decoded.row_count, 1);
    assert_eq!(decoded.column_count, 1);
    println!("✓ Execute query with no plugin uses raw SQL test passed");
}

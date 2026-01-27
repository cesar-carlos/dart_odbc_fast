/// E2E tests for BatchExecutor with real SQL Server connection
use odbc_engine::engine::core::{BatchExecutor, BatchQuery};
use odbc_engine::engine::{OdbcConnection, OdbcEnvironment};
use odbc_engine::protocol::BinaryProtocolDecoder;

mod helpers;
use helpers::e2e::should_run_e2e_tests;
use helpers::env::get_sqlserver_test_dsn;

#[test]
fn test_execute_batch_single_query() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing execute_batch with single query...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Get ODBC connection
    let conn_handles = conn.get_handles();
    let handles = conn_handles.lock().unwrap();
    let odbc_conn = handles
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Create batch executor
    let executor = BatchExecutor::new(100, 10);

    // Create single query
    let query = BatchQuery::new("SELECT 42 AS value".to_string());
    let queries = vec![query];

    // Execute batch
    let results = executor
        .execute_batch(odbc_conn, queries)
        .expect("Failed to execute batch");

    assert_eq!(results.len(), 1, "Should have 1 result");

    // Decode and verify
    let decoded = BinaryProtocolDecoder::parse(&results[0]).expect("Failed to decode result");

    assert_eq!(decoded.column_count, 1, "Should have 1 column");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");
    assert!(decoded.rows[0][0].is_some(), "Value should not be NULL");

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    assert_eq!(value, 42, "Value should be 42");

    drop(handles);
    conn.disconnect().expect("Failed to disconnect");

    println!("✅ Single query batch test PASSED");
}

#[test]
fn test_execute_batch_multiple_queries() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing execute_batch with multiple queries...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Get ODBC connection
    let conn_handles = conn.get_handles();
    let handles = conn_handles.lock().unwrap();
    let odbc_conn = handles
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Create batch executor
    let executor = BatchExecutor::new(100, 10);

    // Create multiple queries
    let queries = vec![
        BatchQuery::new("SELECT 1 AS value".to_string()),
        BatchQuery::new("SELECT 2 AS value".to_string()),
        BatchQuery::new("SELECT 3 AS value".to_string()),
    ];

    // Execute batch
    let results = executor
        .execute_batch(odbc_conn, queries)
        .expect("Failed to execute batch");

    assert_eq!(results.len(), 3, "Should have 3 results");

    // Verify each result
    for (i, result) in results.iter().enumerate() {
        let decoded = BinaryProtocolDecoder::parse(result)
            .unwrap_or_else(|_| panic!("Failed to decode result {}", i + 1));

        assert_eq!(decoded.column_count, 1, "Should have 1 column");
        assert_eq!(decoded.row_count, 1, "Should have 1 row");
        assert!(decoded.rows[0][0].is_some(), "Value should not be NULL");

        let bytes = decoded.rows[0][0].as_ref().unwrap();
        let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        assert_eq!(value, (i + 1) as i32, "Value should be {}", i + 1);
    }

    drop(handles);
    conn.disconnect().expect("Failed to disconnect");

    println!("✅ Multiple queries batch test PASSED");
}

#[test]
fn test_execute_batch_different_result_types() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing execute_batch with different result types...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Get ODBC connection
    let conn_handles = conn.get_handles();
    let handles = conn_handles.lock().unwrap();
    let odbc_conn = handles
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Create batch executor
    let executor = BatchExecutor::new(100, 10);

    // Create queries with different result types
    let queries = vec![
        BatchQuery::new("SELECT 42 AS int_value".to_string()),
        BatchQuery::new("SELECT 'Hello' AS text_value".to_string()),
        BatchQuery::new("SELECT CAST(123.45 AS FLOAT) AS float_value".to_string()),
    ];

    // Execute batch
    let results = executor
        .execute_batch(odbc_conn, queries)
        .expect("Failed to execute batch");

    assert_eq!(results.len(), 3, "Should have 3 results");

    // Verify first result (integer)
    let decoded1 =
        BinaryProtocolDecoder::parse(&results[0]).expect("Failed to decode integer result");
    assert_eq!(decoded1.column_count, 1);
    assert_eq!(decoded1.row_count, 1);

    // Verify second result (text)
    let decoded2 = BinaryProtocolDecoder::parse(&results[1]).expect("Failed to decode text result");
    assert_eq!(decoded2.column_count, 1);
    assert_eq!(decoded2.row_count, 1);
    assert!(decoded2.rows[0][0].is_some(), "Text should not be NULL");

    // Verify third result (float)
    let decoded3 =
        BinaryProtocolDecoder::parse(&results[2]).expect("Failed to decode float result");
    assert_eq!(decoded3.column_count, 1);
    assert_eq!(decoded3.row_count, 1);
    assert!(decoded3.rows[0][0].is_some(), "Float should not be NULL");

    drop(handles);
    conn.disconnect().expect("Failed to disconnect");

    println!("✅ Different result types batch test PASSED");
}

#[test]
fn test_execute_batch_empty_result() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing execute_batch with empty result...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Get ODBC connection
    let conn_handles = conn.get_handles();
    let handles = conn_handles.lock().unwrap();
    let odbc_conn = handles
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Create batch executor
    let executor = BatchExecutor::new(100, 10);

    // Create query that returns no rows
    let queries = vec![BatchQuery::new(
        "SELECT * FROM (SELECT 1 AS value WHERE 1=0) AS t".to_string(),
    )];

    // Execute batch
    let results = executor
        .execute_batch(odbc_conn, queries)
        .expect("Failed to execute batch");

    assert_eq!(results.len(), 1, "Should have 1 result");

    // Decode and verify empty result
    let decoded = BinaryProtocolDecoder::parse(&results[0]).expect("Failed to decode result");

    assert_eq!(decoded.column_count, 1, "Should have 1 column");
    assert_eq!(decoded.row_count, 0, "Should have 0 rows");

    drop(handles);
    conn.disconnect().expect("Failed to disconnect");

    println!("✅ Empty result batch test PASSED");
}

#[test]
fn test_execute_batch_optimized_single_execution() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing execute_batch_optimized with single execution...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Get ODBC connection
    let conn_handles = conn.get_handles();
    let handles = conn_handles.lock().unwrap();
    let odbc_conn = handles
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Create batch executor with batch_size = 5
    let executor = BatchExecutor::new(100, 5);

    // Execute same query once (empty param_sets means no executions, but we'll use one empty set)
    let sql = "SELECT 42 AS value";
    let param_sets = vec![vec![]]; // One empty param set

    // Execute batch optimized
    let results = executor
        .execute_batch_optimized(odbc_conn, sql, param_sets)
        .expect("Failed to execute batch optimized");

    assert_eq!(results.len(), 1, "Should have 1 result");

    // Decode and verify
    let decoded = BinaryProtocolDecoder::parse(&results[0]).expect("Failed to decode result");

    assert_eq!(decoded.column_count, 1, "Should have 1 column");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");
    assert!(decoded.rows[0][0].is_some(), "Value should not be NULL");

    let bytes = decoded.rows[0][0].as_ref().unwrap();
    let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    assert_eq!(value, 42, "Value should be 42");

    drop(handles);
    conn.disconnect().expect("Failed to disconnect");

    println!("✅ Single execution optimized batch test PASSED");
}

#[test]
fn test_execute_batch_optimized_multiple_executions() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing execute_batch_optimized with multiple executions...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Get ODBC connection
    let conn_handles = conn.get_handles();
    let handles = conn_handles.lock().unwrap();
    let odbc_conn = handles
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Create batch executor with batch_size = 2
    let executor = BatchExecutor::new(100, 2);

    // Execute same query 3 times (will be split into 2 batches: 2 + 1)
    let sql = "SELECT 100 AS value";
    let param_sets = vec![vec![], vec![], vec![]]; // Three empty param sets

    // Execute batch optimized
    let results = executor
        .execute_batch_optimized(odbc_conn, sql, param_sets)
        .expect("Failed to execute batch optimized");

    assert_eq!(results.len(), 3, "Should have 3 results");

    // Verify each result
    for result in results.iter() {
        let decoded = BinaryProtocolDecoder::parse(result).expect("Failed to decode result");

        assert_eq!(decoded.column_count, 1, "Should have 1 column");
        assert_eq!(decoded.row_count, 1, "Should have 1 row");
        assert!(decoded.rows[0][0].is_some(), "Value should not be NULL");

        let bytes = decoded.rows[0][0].as_ref().unwrap();
        let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        assert_eq!(value, 100, "Value should be 100");
    }

    drop(handles);
    conn.disconnect().expect("Failed to disconnect");

    println!("✅ Multiple executions optimized batch test PASSED");
}

#[test]
fn test_execute_batch_optimized_with_batch_size_chunking() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing execute_batch_optimized with batch size chunking...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Get ODBC connection
    let conn_handles = conn.get_handles();
    let handles = conn_handles.lock().unwrap();
    let odbc_conn = handles
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Create batch executor with batch_size = 2 (will chunk into groups of 2)
    let executor = BatchExecutor::new(100, 2);

    // Execute same query 5 times (will be split into 3 batches: 2 + 2 + 1)
    let sql = "SELECT 200 AS value";
    let param_sets = vec![vec![], vec![], vec![], vec![], vec![]]; // Five empty param sets

    // Execute batch optimized
    let results = executor
        .execute_batch_optimized(odbc_conn, sql, param_sets)
        .expect("Failed to execute batch optimized");

    assert_eq!(
        results.len(),
        5,
        "Should have 5 results (one per param_set)"
    );

    // Verify each result
    for (i, result) in results.iter().enumerate() {
        let decoded = BinaryProtocolDecoder::parse(result)
            .unwrap_or_else(|_| panic!("Failed to decode result {}", i + 1));

        assert_eq!(decoded.column_count, 1, "Should have 1 column");
        assert_eq!(decoded.row_count, 1, "Should have 1 row");
        assert!(decoded.rows[0][0].is_some(), "Value should not be NULL");

        let bytes = decoded.rows[0][0].as_ref().unwrap();
        let value = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        assert_eq!(value, 200, "Value should be 200");
    }

    drop(handles);
    conn.disconnect().expect("Failed to disconnect");

    println!("✅ Batch size chunking optimized batch test PASSED");
}

#[test]
fn test_execute_batch_optimized_multiple_columns() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing execute_batch_optimized with multiple columns...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");
    println!("✓ Connected to SQL Server");

    // Get ODBC connection
    let conn_handles = conn.get_handles();
    let handles = conn_handles.lock().unwrap();
    let odbc_conn = handles
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Create batch executor
    let executor = BatchExecutor::new(100, 10);

    // Execute query with multiple columns
    let sql = "SELECT 1 AS col1, 'test' AS col2, CAST(3.14 AS FLOAT) AS col3";
    let param_sets = vec![vec![]]; // One empty param set

    // Execute batch optimized
    let results = executor
        .execute_batch_optimized(odbc_conn, sql, param_sets)
        .expect("Failed to execute batch optimized");

    assert_eq!(results.len(), 1, "Should have 1 result");

    // Decode and verify
    let decoded = BinaryProtocolDecoder::parse(&results[0]).expect("Failed to decode result");

    assert_eq!(decoded.column_count, 3, "Should have 3 columns");
    assert_eq!(decoded.row_count, 1, "Should have 1 row");

    // Verify all columns are not NULL
    for col_idx in 0..3 {
        assert!(
            decoded.rows[0][col_idx].is_some(),
            "Column {} should not be NULL",
            col_idx + 1
        );
    }

    drop(handles);
    conn.disconnect().expect("Failed to disconnect");

    println!("✅ Multiple columns optimized batch test PASSED");
}

#[test]
fn test_execute_batch_query_fails_midway() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    let executor = BatchExecutor::new(100, 10);
    let queries = vec![
        BatchQuery::new("SELECT 1 AS value".to_string()),
        BatchQuery::new("SELECT * FROM nonexistent_table_xyz_12345".to_string()),
        BatchQuery::new("SELECT 3 AS value".to_string()),
    ];

    let result = executor.execute_batch(odbc_conn, queries);

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    assert!(
        result.is_err(),
        "Batch with invalid query in middle should return Err"
    );
    println!("✅ Execute batch query fails midway test PASSED");
}

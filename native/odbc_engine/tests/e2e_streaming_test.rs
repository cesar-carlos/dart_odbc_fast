/// E2E tests for StreamingExecutor with real SQL Server connection
use odbc_engine::engine::{OdbcConnection, OdbcEnvironment, StreamingExecutor};
use odbc_engine::protocol::BinaryProtocolDecoder;

mod helpers;
use helpers::e2e::should_run_e2e_tests;
use helpers::env::get_sqlserver_test_dsn;

#[test]
fn test_streaming_small_result_set() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing streaming with small result set (5 rows)...");

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

    // Create streaming executor with small chunk size
    let executor = StreamingExecutor::new(1024);

    // Execute streaming query
    let sql = "SELECT number FROM (SELECT 1 AS number UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5) AS t ORDER BY number";
    println!("Executing: {}", sql);

    let mut state = executor
        .execute_streaming(odbc_conn, sql)
        .expect("Failed to execute streaming query");
    println!("✓ Streaming query executed");

    // Fetch all chunks
    let mut chunks = Vec::new();
    let mut chunk_count = 0;
    while let Some(chunk) = state.fetch_next_chunk().expect("Failed to fetch chunk") {
        chunk_count += 1;
        chunks.push(chunk);
        println!(
            "✓ Fetched chunk {} ({} bytes)",
            chunk_count,
            chunks.last().unwrap().len()
        );
    }

    println!("✓ Fetched {} total chunks", chunk_count);

    // Reconstruct full buffer
    let full_buffer: Vec<u8> = chunks.into_iter().flatten().collect();

    // Decode and verify
    let decoded = BinaryProtocolDecoder::parse(&full_buffer).expect("Failed to decode result");

    assert_eq!(decoded.column_count, 1, "Should have 1 column");
    assert_eq!(decoded.row_count, 5, "Should have 5 rows");

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
    println!("✓ All 5 rows verified");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("\n✅ Streaming small result set test PASSED");
}

#[test]
fn test_streaming_large_result_set() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing streaming with large result set (100 rows)...");

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

    // Create streaming executor with small chunk size to force multiple chunks
    let executor = StreamingExecutor::new(512); // Small chunk size

    // Generate 100 rows
    let sql = "
        WITH Numbers AS (
            SELECT 1 AS n
            UNION ALL SELECT 2
            UNION ALL SELECT 3
            UNION ALL SELECT 4
            UNION ALL SELECT 5
            UNION ALL SELECT 6
            UNION ALL SELECT 7
            UNION ALL SELECT 8
            UNION ALL SELECT 9
            UNION ALL SELECT 10
        )
        SELECT 
            (a.n - 1) * 10 + b.n AS number
        FROM Numbers a
        CROSS JOIN Numbers b
        ORDER BY number
    ";
    println!("Executing query for 100 rows...");

    let mut state = executor
        .execute_streaming(odbc_conn, sql)
        .expect("Failed to execute streaming query");
    println!("✓ Streaming query executed");

    // Fetch all chunks
    let mut chunks = Vec::new();
    let mut chunk_count = 0;
    while let Some(chunk) = state.fetch_next_chunk().expect("Failed to fetch chunk") {
        chunk_count += 1;
        chunks.push(chunk);
    }
    println!("✓ Fetched {} total chunks", chunk_count);
    assert!(
        chunk_count > 1,
        "Should have multiple chunks with small chunk size"
    );

    // Reconstruct full buffer
    let full_buffer: Vec<u8> = chunks.into_iter().flatten().collect();

    // Decode and verify
    let decoded = BinaryProtocolDecoder::parse(&full_buffer).expect("Failed to decode result");

    assert_eq!(decoded.column_count, 1, "Should have 1 column");
    assert_eq!(decoded.row_count, 100, "Should have 100 rows");
    println!("✓ All 100 rows received");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("\n✅ Streaming large result set test PASSED");
}

#[test]
fn test_streaming_multiple_columns() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing streaming with multiple columns...");

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

    // Create streaming executor
    let executor = StreamingExecutor::new(2048);

    // Execute query with multiple columns
    let sql = "
        SELECT 
            number,
            number * 2 AS doubled,
            'row_' + CAST(number AS VARCHAR(10)) AS label
        FROM (
            SELECT 1 AS number UNION ALL 
            SELECT 2 UNION ALL 
            SELECT 3
        ) AS t
    ";
    println!("Executing multi-column query...");

    let mut state = executor
        .execute_streaming(odbc_conn, sql)
        .expect("Failed to execute streaming query");
    println!("✓ Streaming query executed");

    // Fetch all chunks
    let mut chunks = Vec::new();
    while let Some(chunk) = state.fetch_next_chunk().expect("Failed to fetch chunk") {
        chunks.push(chunk);
    }

    // Reconstruct and decode
    let full_buffer: Vec<u8> = chunks.into_iter().flatten().collect();
    let decoded = BinaryProtocolDecoder::parse(&full_buffer).expect("Failed to decode result");

    assert_eq!(decoded.column_count, 3, "Should have 3 columns");
    assert_eq!(decoded.row_count, 3, "Should have 3 rows");

    // Verify column names
    assert_eq!(decoded.columns[0].name, "number");
    assert_eq!(decoded.columns[1].name, "doubled");
    assert_eq!(decoded.columns[2].name, "label");
    println!("✓ Column names verified");

    // Verify first row data
    let row1 = &decoded.rows[0];
    let num_bytes = row1[0].as_ref().unwrap();
    let number = i32::from_le_bytes([num_bytes[0], num_bytes[1], num_bytes[2], num_bytes[3]]);
    assert_eq!(number, 1);

    let doubled_bytes = row1[1].as_ref().unwrap();
    let doubled = i32::from_le_bytes([
        doubled_bytes[0],
        doubled_bytes[1],
        doubled_bytes[2],
        doubled_bytes[3],
    ]);
    assert_eq!(doubled, 2);

    let label_bytes = row1[2].as_ref().unwrap();
    let label = String::from_utf8_lossy(label_bytes);
    assert_eq!(label, "row_1");
    println!("✓ Row 1 data verified");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("\n✅ Streaming multiple columns test PASSED");
}

#[test]
fn test_streaming_with_nulls() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing streaming with NULL values...");

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

    // Create streaming executor
    let executor = StreamingExecutor::new(1024);

    // Execute query with NULLs
    let sql = "
        SELECT number, name 
        FROM (
            SELECT 1 AS number, 'Alice' AS name
            UNION ALL SELECT 2, NULL
            UNION ALL SELECT NULL, 'Bob'
            UNION ALL SELECT 4, 'Charlie'
        ) AS t
        ORDER BY CASE WHEN number IS NULL THEN 999 ELSE number END
    ";
    println!("Executing query with NULLs...");

    let mut state = executor
        .execute_streaming(odbc_conn, sql)
        .expect("Failed to execute streaming query");
    println!("✓ Streaming query executed");

    // Fetch and reconstruct
    let mut chunks = Vec::new();
    while let Some(chunk) = state.fetch_next_chunk().expect("Failed to fetch chunk") {
        chunks.push(chunk);
    }

    let full_buffer: Vec<u8> = chunks.into_iter().flatten().collect();
    let decoded = BinaryProtocolDecoder::parse(&full_buffer).expect("Failed to decode result");

    assert_eq!(decoded.column_count, 2);
    assert_eq!(decoded.row_count, 4);

    // Verify that we have the expected mix of NULL and non-NULL values
    // Count NULLs in each column
    let mut col1_nulls = 0;
    let mut col2_nulls = 0;

    for row in &decoded.rows {
        if row[0].is_none() {
            col1_nulls += 1;
        }
        if row[1].is_none() {
            col2_nulls += 1;
        }
    }

    // We expect 1 NULL in column 1 and 1 NULL in column 2
    assert_eq!(col1_nulls, 1, "Should have exactly 1 NULL in column 1");
    assert_eq!(col2_nulls, 1, "Should have exactly 1 NULL in column 2");

    println!("✓ NULL values handled correctly");

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("\n✅ Streaming with NULLs test PASSED");
}

#[test]
fn test_streaming_different_chunk_sizes() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing streaming with different chunk sizes...");

    // Test with chunk sizes: 256, 512, 1024, 2048
    let chunk_sizes = vec![256, 512, 1024, 2048];

    for chunk_size in chunk_sizes {
        println!("\n--- Testing chunk size: {} bytes ---", chunk_size);

        // Initialize and connect
        let env = OdbcEnvironment::new();
        env.init().expect("Failed to initialize ODBC environment");
        let handles = env.get_handles();
        let conn =
            OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

        // Get ODBC connection
        let conn_handles = conn.get_handles();
        let handles_guard = conn_handles.lock().unwrap();
        let odbc_conn = handles_guard
            .get_connection(conn.get_connection_id())
            .expect("Failed to get ODBC connection handle");

        // Create streaming executor with specific chunk size
        let executor = StreamingExecutor::new(chunk_size);

        // Execute query
        let sql = "SELECT number FROM (SELECT 1 AS number UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10) AS t";

        let mut state = executor
            .execute_streaming(odbc_conn, sql)
            .expect("Failed to execute streaming query");

        // Fetch all chunks
        let mut chunks = Vec::new();
        while let Some(chunk) = state.fetch_next_chunk().expect("Failed to fetch chunk") {
            chunks.push(chunk);
        }

        println!("✓ Fetched {} chunks with size {}", chunks.len(), chunk_size);

        // Reconstruct and verify
        let full_buffer: Vec<u8> = chunks.into_iter().flatten().collect();
        let decoded = BinaryProtocolDecoder::parse(&full_buffer).expect("Failed to decode result");

        assert_eq!(
            decoded.row_count, 10,
            "Should have 10 rows for chunk size {}",
            chunk_size
        );

        drop(handles_guard);
        conn.disconnect().expect("Failed to disconnect");
    }

    println!("\n✅ Different chunk sizes test PASSED");
}

#[test]
fn test_streaming_has_more() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing StreamingState.has_more()...");

    // Initialize and connect
    let env = OdbcEnvironment::new();
    env.init().expect("Failed to initialize ODBC environment");
    let handles = env.get_handles();
    let conn =
        OdbcConnection::connect(handles, &conn_str).expect("Failed to connect to SQL Server");

    // Get ODBC connection
    let conn_handles = conn.get_handles();
    let handles_guard = conn_handles.lock().unwrap();
    let odbc_conn = handles_guard
        .get_connection(conn.get_connection_id())
        .expect("Failed to get ODBC connection handle");

    // Create streaming executor with very small chunk size
    let executor = StreamingExecutor::new(100); // Very small

    // Execute query
    let sql = "SELECT number FROM (SELECT 1 AS number UNION ALL SELECT 2 UNION ALL SELECT 3) AS t";

    let mut state = executor
        .execute_streaming(odbc_conn, sql)
        .expect("Failed to execute streaming query");

    // Verify has_more() behavior
    let mut chunk_count = 0;
    while state.has_more() {
        assert!(state.has_more(), "has_more() should be true before fetch");
        let chunk = state.fetch_next_chunk().expect("Failed to fetch chunk");
        assert!(
            chunk.is_some(),
            "Chunk should exist when has_more() is true"
        );
        chunk_count += 1;
    }

    // After exhausting, has_more() should be false
    assert!(
        !state.has_more(),
        "has_more() should be false after exhausting"
    );

    let final_chunk = state
        .fetch_next_chunk()
        .expect("Failed to fetch final chunk");
    assert!(final_chunk.is_none(), "Should return None after exhausting");

    println!("✓ has_more() behavior verified ({} chunks)", chunk_count);

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("\n✅ has_more() test PASSED");
}

/// True cursor-based lazy streaming: execute_streaming_batched fetches in small
/// batches and invokes the callback per batch. Memory footprint is bounded by
/// one batch instead of loading the full result set.
#[test]
fn test_streaming_batched_lazy() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing execute_streaming_batched (lazy cursor-based)...");

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

    let executor = StreamingExecutor::new(1024);
    let sql = "SELECT number FROM (SELECT 1 AS number UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5) AS t ORDER BY number";
    const FETCH_SIZE: usize = 2;

    let mut batches: Vec<Vec<u8>> = Vec::new();
    executor
        .execute_streaming_batched(odbc_conn, sql, FETCH_SIZE, |encoded| {
            batches.push(encoded);
            Ok(())
        })
        .expect("execute_streaming_batched failed");

    let mut total_rows = 0_usize;
    for (i, batch) in batches.iter().enumerate() {
        let decoded = BinaryProtocolDecoder::parse(batch).expect("Failed to decode batch");
        total_rows += decoded.row_count;
        println!("  Batch {}: {} rows", i + 1, decoded.row_count);
    }

    assert!(
        batches.len() >= 2,
        "Expected multiple batches with fetch_size={}",
        FETCH_SIZE
    );
    assert_eq!(total_rows, 5, "Expected 5 rows total");
    println!(
        "✓ Received {} batches, {} rows total",
        batches.len(),
        total_rows
    );

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("\n✅ execute_streaming_batched (lazy) test PASSED");
}

/// Batched streaming with a larger result set (1000 rows, fetch_size=100).
/// Exercises bounded-memory path; 50k rows would use fetch_size=1000 for stress.
#[test]
fn test_streaming_batched_large_result() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing execute_streaming_batched with larger result (1000 rows, fetch_size=100)...");

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

    let executor = StreamingExecutor::new(1024);
    let sql = ";WITH n(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM n WHERE n < 1000) SELECT n FROM n OPTION (MAXRECURSION 1000)";
    const FETCH_SIZE: usize = 100;

    let mut batches: Vec<Vec<u8>> = Vec::new();
    executor
        .execute_streaming_batched(odbc_conn, sql, FETCH_SIZE, |encoded| {
            batches.push(encoded);
            Ok(())
        })
        .expect("execute_streaming_batched failed");

    let mut total_rows = 0_usize;
    for (i, batch) in batches.iter().enumerate() {
        let decoded = BinaryProtocolDecoder::parse(batch).expect("Failed to decode batch");
        total_rows += decoded.row_count;
        if i < 3 || batches.len() - i <= 2 {
            println!("  Batch {}: {} rows", i + 1, decoded.row_count);
        } else if i == 3 {
            println!("  ...");
        }
    }

    assert!(
        batches.len() >= 2,
        "Expected multiple batches with fetch_size={}",
        FETCH_SIZE
    );
    assert_eq!(total_rows, 1000, "Expected 1000 rows total");
    println!(
        "✓ Received {} batches, {} rows total",
        batches.len(),
        total_rows
    );

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    println!("\n✅ execute_streaming_batched (large result) test PASSED");
}

#[test]
fn test_streaming_invalid_sql_returns_error() {
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

    let executor = StreamingExecutor::new(1024);
    let invalid_sql = "SELECT * FROM nonexistent_table_xyz_12345";
    let result = executor.execute_streaming(odbc_conn, invalid_sql);

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    assert!(result.is_err(), "Invalid SQL should return Err");
    println!("✓ Streaming invalid SQL returns error test passed");
}

#[test]
fn test_streaming_batched_empty_result() {
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

    let executor = StreamingExecutor::new(1024);
    let sql = "SELECT 1 AS n WHERE 1 = 0";
    let mut batch_count = 0_usize;
    executor
        .execute_streaming_batched(odbc_conn, sql, 10, |_| {
            batch_count += 1;
            Ok(())
        })
        .expect("execute_streaming_batched should succeed for empty result");

    assert!(batch_count >= 1, "Empty result still produces one encoded batch");
    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");
    println!("✓ Streaming batched empty result test passed");
}

#[test]
fn test_streaming_batched_callback_error_propagates() {
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

    let executor = StreamingExecutor::new(1024);
    let sql = "SELECT number FROM (SELECT 1 AS number UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5) AS t ORDER BY number";
    let mut call_count = 0_u32;
    let result = executor.execute_streaming_batched(odbc_conn, sql, 2, |_| {
        call_count += 1;
        if call_count >= 2 {
            Err(odbc_engine::OdbcError::InternalError(
                "callback error".to_string(),
            ))
        } else {
            Ok(())
        }
    });

    drop(handles_guard);
    conn.disconnect().expect("Failed to disconnect");

    assert!(result.is_err(), "Callback error should propagate");
    assert!(call_count >= 2, "Callback should be invoked at least twice");
    println!("✓ Streaming batched callback error propagates test passed");
}

/// E2E tests for ConnectionPool with real SQL Server connection
use odbc_engine::pool::ConnectionPool;
use std::sync::Arc;

mod helpers;
use helpers::e2e::should_run_e2e_tests;
use helpers::env::get_sqlserver_test_dsn;

#[test]
fn test_pool_creation() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing pool creation...");

    let pool = ConnectionPool::new(&conn_str, 5).expect("Failed to create connection pool");

    assert_eq!(pool.max_size(), 5, "Max size should be 5");
    assert_eq!(
        pool.connection_string(),
        conn_str,
        "Connection string should match"
    );

    println!("✅ Pool creation test PASSED");
}

#[test]
fn test_pool_get_connection() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing pool get connection...");

    let pool = ConnectionPool::new(&conn_str, 5).expect("Failed to create connection pool");

    let wrapper = pool.get().expect("Failed to get connection from pool");

    // Verify we can use the connection
    {
        let conn = wrapper.get_connection();
        let mut stmt = conn
            .prepare("SELECT 1 AS value")
            .expect("Failed to prepare statement");

        let cursor = stmt.execute(()).expect("Failed to execute query");

        assert!(cursor.is_some(), "Should have result");
    }

    drop(wrapper);

    println!("✅ Pool get connection test PASSED");
}

#[test]
fn test_pool_health_check() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing pool health check...");

    let pool = ConnectionPool::new(&conn_str, 5).expect("Failed to create connection pool");

    let is_healthy = pool.health_check();
    assert!(is_healthy, "Pool should be healthy");

    println!("✅ Pool health check test PASSED");
}

#[test]
fn test_pool_state_initial() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing pool initial state...");

    let pool = ConnectionPool::new(&conn_str, 5).expect("Failed to create connection pool");

    let state = pool.state();
    println!("Initial state: size={}, idle={}", state.size, state.idle);

    // Initially, pool may have 0 connections (lazy initialization) or pre-created connections
    // r2d2 may pre-create connections, so we just verify state is valid
    assert!(
        state.size <= pool.max_size(),
        "Pool size should not exceed max_size"
    );
    assert!(state.idle <= state.size, "Idle should not exceed size");

    println!("✅ Pool initial state test PASSED");
}

#[test]
fn test_pool_state_after_get() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing pool state after getting connection...");

    let pool = ConnectionPool::new(&conn_str, 5).expect("Failed to create connection pool");

    let initial_state = pool.state();
    println!(
        "Initial state: size={}, idle={}",
        initial_state.size, initial_state.idle
    );

    // Get a connection
    let wrapper = pool.get().expect("Failed to get connection from pool");

    let state_after_get = pool.state();
    println!(
        "State after get: size={}, idle={}",
        state_after_get.size, state_after_get.idle
    );

    // After getting a connection, size should increase (if new connection created) or stay same (if reused)
    // Idle should decrease (connection is in use)
    assert!(
        state_after_get.size >= 1,
        "Pool size should be at least 1 after getting connection"
    );
    assert!(
        state_after_get.size <= pool.max_size(),
        "Pool size should not exceed max_size"
    );
    assert!(
        state_after_get.idle < initial_state.idle || state_after_get.size > initial_state.size,
        "Either idle decreased or size increased"
    );

    // Release connection (drop wrapper)
    drop(wrapper);

    // Give a small moment for the connection to be returned to pool
    std::thread::sleep(std::time::Duration::from_millis(100));

    let state_after_release = pool.state();
    println!(
        "State after release: size={}, idle={}",
        state_after_release.size, state_after_release.idle
    );

    // After releasing, size should be maintained, and idle should increase
    assert!(
        state_after_release.size >= 1,
        "Pool size should be at least 1"
    );
    assert!(
        state_after_release.idle >= 1,
        "Idle should be at least 1 (connection returned to pool)"
    );
    assert!(
        state_after_release.idle <= state_after_release.size,
        "Idle should not exceed size"
    );

    println!("✅ Pool state after get test PASSED");
}

#[test]
fn test_pool_multiple_connections() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing pool with multiple connections...");

    let pool = ConnectionPool::new(&conn_str, 3).expect("Failed to create connection pool");

    // Get 3 connections
    let wrapper1 = pool.get().expect("Failed to get connection 1");
    let wrapper2 = pool.get().expect("Failed to get connection 2");
    let wrapper3 = pool.get().expect("Failed to get connection 3");

    let state = pool.state();
    println!(
        "State with 3 connections: size={}, idle={}",
        state.size, state.idle
    );

    assert_eq!(state.size, 3, "Pool size should be 3");
    assert_eq!(state.idle, 0, "Idle should be 0 (all connections in use)");

    // Verify all connections work
    {
        let conn1 = wrapper1.get_connection();
        let mut stmt1 = conn1
            .prepare("SELECT 1 AS value")
            .expect("Failed to prepare statement 1");
        let cursor1 = stmt1.execute(()).expect("Failed to execute query 1");
        assert!(cursor1.is_some(), "Connection 1 should work");

        let conn2 = wrapper2.get_connection();
        let mut stmt2 = conn2
            .prepare("SELECT 2 AS value")
            .expect("Failed to prepare statement 2");
        let cursor2 = stmt2.execute(()).expect("Failed to execute query 2");
        assert!(cursor2.is_some(), "Connection 2 should work");

        let conn3 = wrapper3.get_connection();
        let mut stmt3 = conn3
            .prepare("SELECT 3 AS value")
            .expect("Failed to prepare statement 3");
        let cursor3 = stmt3.execute(()).expect("Failed to execute query 3");
        assert!(cursor3.is_some(), "Connection 3 should work");
    }

    // Release all connections
    drop(wrapper1);
    drop(wrapper2);
    drop(wrapper3);

    // Give a moment for connections to be returned
    std::thread::sleep(std::time::Duration::from_millis(100));

    let state_after_release = pool.state();
    println!(
        "State after release: size={}, idle={}",
        state_after_release.size, state_after_release.idle
    );

    assert_eq!(state_after_release.size, 3, "Pool size should still be 3");
    assert_eq!(
        state_after_release.idle, 3,
        "Idle should be 3 (all connections returned)"
    );

    println!("✅ Multiple connections test PASSED");
}

#[test]
fn test_pool_connection_reuse() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing pool connection reuse...");

    let pool = ConnectionPool::new(&conn_str, 2).expect("Failed to create connection pool");

    // Get and release connection multiple times
    for i in 1..=5 {
        let wrapper = pool
            .get()
            .unwrap_or_else(|_| panic!("Failed to get connection on iteration {}", i));

        {
            let conn = wrapper.get_connection();
            let mut stmt = conn
                .prepare(&format!("SELECT {} AS value", i))
                .unwrap_or_else(|_| panic!("Failed to prepare statement on iteration {}", i));

            let cursor = stmt
                .execute(())
                .unwrap_or_else(|_| panic!("Failed to execute query on iteration {}", i));

            assert!(cursor.is_some(), "Query should succeed on iteration {}", i);
        }

        // Release connection
        drop(wrapper);

        // Small delay to allow connection to be returned
        std::thread::sleep(std::time::Duration::from_millis(50));
    }

    // After multiple get/release cycles, pool should still have connections
    let state = pool.state();
    println!("Final state: size={}, idle={}", state.size, state.idle);

    // Pool should have at least 1 connection (reused)
    assert!(state.size >= 1, "Pool should have at least 1 connection");
    assert!(
        state.idle >= 1,
        "Pool should have at least 1 idle connection"
    );

    println!("✅ Connection reuse test PASSED");
}

#[test]
fn test_pool_max_size_limit() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing pool max size limit...");

    let pool = ConnectionPool::new(&conn_str, 2).expect("Failed to create connection pool");

    assert_eq!(pool.max_size(), 2, "Max size should be 2");

    // Get 2 connections (max size)
    let wrapper1 = pool.get().expect("Failed to get connection 1");
    let wrapper2 = pool.get().expect("Failed to get connection 2");

    let state = pool.state();
    assert_eq!(state.size, 2, "Pool size should be 2");

    // Try to get a third connection - should timeout or wait
    // Note: r2d2 will wait for a connection to become available (up to timeout)
    // Since we're holding 2 connections, the third get() should wait
    // We'll test this by getting a third connection in a separate thread with timeout

    let pool_arc = Arc::new(pool);
    let pool_clone = Arc::clone(&pool_arc);
    let handle = std::thread::spawn(move || {
        // This should wait for a connection to become available
        pool_clone.get()
    });

    // Wait a bit, then release one connection
    std::thread::sleep(std::time::Duration::from_millis(500));
    drop(wrapper1);

    // The third connection should now succeed
    let wrapper3_result = handle.join().expect("Thread should complete");

    let wrapper3 =
        wrapper3_result.expect("Should be able to get third connection after releasing one");

    let state_after = pool_arc.state();
    assert_eq!(state_after.size, 2, "Pool size should still be 2 (max)");

    drop(wrapper2);
    drop(wrapper3);

    println!("✅ Max size limit test PASSED");
}

#[test]
fn test_pool_concurrent_access() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing pool concurrent access...");

    let pool =
        Arc::new(ConnectionPool::new(&conn_str, 5).expect("Failed to create connection pool"));

    let mut handles = Vec::new();

    // Spawn 10 threads, each getting and using a connection
    for i in 0..10 {
        let pool_clone = Arc::clone(&pool);
        let handle = std::thread::spawn(move || {
            let wrapper = pool_clone
                .get()
                .unwrap_or_else(|_| panic!("Thread {}: Failed to get connection", i));

            {
                let conn = wrapper.get_connection();
                let mut stmt = conn
                    .prepare(&format!("SELECT {} AS value", i))
                    .unwrap_or_else(|_| panic!("Thread {}: Failed to prepare statement", i));

                let cursor = stmt
                    .execute(())
                    .unwrap_or_else(|_| panic!("Thread {}: Failed to execute query", i));

                assert!(cursor.is_some(), "Thread {}: Query should succeed", i);
            }

            // Hold connection for a bit
            std::thread::sleep(std::time::Duration::from_millis(100));

            // Connection is released when wrapper is dropped
        });

        handles.push(handle);
    }

    // Wait for all threads to complete
    for handle in handles {
        handle.join().expect("Thread should complete");
    }

    // Give a moment for all connections to be returned
    std::thread::sleep(std::time::Duration::from_millis(200));

    let state = pool.state();
    println!(
        "Final state after concurrent access: size={}, idle={}",
        state.size, state.idle
    );

    // Pool should have connections (up to max_size)
    assert!(
        state.size <= pool.max_size(),
        "Pool size should not exceed max_size"
    );
    assert!(state.idle <= state.size, "Idle should not exceed size");

    println!("✅ Concurrent access test PASSED");
}

/// Pool integration: when a connection is returned after being left in
/// manual-commit mode (e.g. from a transaction), the next checkout runs
/// is_valid (test_on_check_out), which resets autocommit and runs SELECT 1.
/// This ensures connections are in a clean state for reuse.
#[test]
fn test_pool_transaction_reset_state() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        eprintln!("   Set SQLSERVER_TEST_* environment variables or ODBC_TEST_DSN");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build SQL Server connection string");

    println!("Testing pool transaction reset state...");

    let pool = ConnectionPool::new(&conn_str, 2).expect("Failed to create connection pool");

    {
        let mut wrapper = pool.get().expect("Failed to get connection");
        let conn = wrapper.get_connection_mut();
        conn.set_autocommit(false)
            .expect("Failed to set autocommit off");
        let mut stmt = conn.prepare("SELECT 1 AS v").expect("Failed to prepare");
        let _ = stmt.execute(()).expect("Failed to execute");
    }

    let wrapper2 = pool.get().expect("Failed to get connection after return");
    let conn2 = wrapper2.get_connection();
    let mut stmt2 = conn2
        .prepare("SELECT 2 AS v")
        .expect("Failed to prepare after reset");
    let cur = stmt2.execute(()).expect("Failed to execute after reset");
    assert!(cur.is_some(), "Query after reuse should succeed");

    println!("✅ Transaction reset state test PASSED");
}

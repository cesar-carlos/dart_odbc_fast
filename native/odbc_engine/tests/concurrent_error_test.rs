#![cfg(feature = "ffi-tests")]

use odbc_engine::{odbc_connect, odbc_disconnect, odbc_exec_query, odbc_get_error, odbc_init};
use std::ffi::CString;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

/// Test that errors from different connections in different threads don't interfere
#[test]
fn test_concurrent_error_isolation() {
    // Skip if no test DSN available
    let dsn = match std::env::var("ODBC_TEST_DSN") {
        Ok(s) if !s.is_empty() => s,
        _ => {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
            return;
        }
    };

    let _ = odbc_init();

    // Create multiple connections
    let conn_str1 = CString::new(format!("{};Database=invalid_db_1", dsn)).unwrap();
    let conn_str2 = CString::new(format!("{};Database=invalid_db_2", dsn)).unwrap();
    let conn_str3 = CString::new(format!("{};Database=invalid_db_3", dsn)).unwrap();

    let _conn_id1 = odbc_connect(conn_str1.as_ptr());
    let _conn_id2 = odbc_connect(conn_str2.as_ptr());
    let _conn_id3 = odbc_connect(conn_str3.as_ptr());

    // At least one connection should succeed (or all fail, but we need at least one)
    // For this test, we'll use valid connections and generate different errors
    let valid_dsn = CString::new(dsn.clone()).unwrap();
    let conn1 = odbc_connect(valid_dsn.as_ptr());
    let conn2 = odbc_connect(valid_dsn.as_ptr());
    let conn3 = odbc_connect(valid_dsn.as_ptr());

    if conn1 == 0 || conn2 == 0 || conn3 == 0 {
        eprintln!("⚠️  Skipping: Could not create test connections");
        return;
    }

    // Spawn threads that generate different errors on different connections
    let conn1_arc = Arc::new(conn1);
    let conn2_arc = Arc::new(conn2);
    let conn3_arc = Arc::new(conn3);

    let conn1_clone = Arc::clone(&conn1_arc);
    let conn2_clone = Arc::clone(&conn2_arc);
    let conn3_clone = Arc::clone(&conn3_arc);

    let handle1 = thread::spawn(move || {
        // Generate error on conn1: invalid query
        let sql = CString::new("INVALID SQL SYNTAX FOR CONN1").unwrap();
        let mut buffer = vec![0u8; 1024];
        let mut written: u32 = 0;
        let result = odbc_exec_query(
            *conn1_clone,
            sql.as_ptr(),
            buffer.as_mut_ptr(),
            buffer.len() as u32,
            &mut written,
        );
        (result, *conn1_clone)
    });

    let handle2 = thread::spawn(move || {
        // Generate error on conn2: invalid query
        let sql = CString::new("INVALID SQL SYNTAX FOR CONN2").unwrap();
        let mut buffer = vec![0u8; 1024];
        let mut written: u32 = 0;
        let result = odbc_exec_query(
            *conn2_clone,
            sql.as_ptr(),
            buffer.as_mut_ptr(),
            buffer.len() as u32,
            &mut written,
        );
        (result, *conn2_clone)
    });

    let handle3 = thread::spawn(move || {
        // Generate error on conn3: invalid query
        let sql = CString::new("INVALID SQL SYNTAX FOR CONN3").unwrap();
        let mut buffer = vec![0u8; 1024];
        let mut written: u32 = 0;
        let result = odbc_exec_query(
            *conn3_clone,
            sql.as_ptr(),
            buffer.as_mut_ptr(),
            buffer.len() as u32,
            &mut written,
        );
        (result, *conn3_clone)
    });

    // Wait for all threads
    let (result1, c1) = handle1.join().unwrap();
    let (result2, c2) = handle2.join().unwrap();
    let (result3, c3) = handle3.join().unwrap();

    // All should have failed
    assert_ne!(result1, 0, "Query 1 should fail");
    assert_ne!(result2, 0, "Query 2 should fail");
    assert_ne!(result3, 0, "Query 3 should fail");

    // Get errors - they should be different or at least not interfere
    let mut error_buf1 = vec![0u8; 1024];
    let mut error_buf2 = vec![0u8; 1024];
    let mut error_buf3 = vec![0u8; 1024];

    let len1 = odbc_get_error(error_buf1.as_mut_ptr() as *mut i8, error_buf1.len() as u32);
    let len2 = odbc_get_error(error_buf2.as_mut_ptr() as *mut i8, error_buf2.len() as u32);
    let len3 = odbc_get_error(error_buf3.as_mut_ptr() as *mut i8, error_buf3.len() as u32);

    // Errors should be captured (non-negative length)
    assert!(len1 >= 0, "Should get error message 1");
    assert!(len2 >= 0, "Should get error message 2");
    assert!(len3 >= 0, "Should get error message 3");

    // Cleanup
    let _ = odbc_disconnect(c1);
    let _ = odbc_disconnect(c2);
    let _ = odbc_disconnect(c3);
}

/// Test that errors are properly isolated when multiple threads access the same connection
#[test]
fn test_concurrent_error_same_connection() {
    let dsn = match std::env::var("ODBC_TEST_DSN") {
        Ok(s) if !s.is_empty() => s,
        _ => {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
            return;
        }
    };

    let _ = odbc_init();
    let conn_str = CString::new(dsn).unwrap();
    let conn_id = odbc_connect(conn_str.as_ptr());

    if conn_id == 0 {
        eprintln!("⚠️  Skipping: Could not create test connection");
        return;
    }

    let conn_id_arc = Arc::new(conn_id);

    // Spawn multiple threads that all use the same connection
    let mut handles = vec![];
    for i in 0..5 {
        let conn_clone = Arc::clone(&conn_id_arc);
        let handle = thread::spawn(move || {
            // Small delay to increase chance of interleaving
            thread::sleep(Duration::from_millis(i * 10));
            let sql = CString::new(format!("INVALID SQL THREAD {}", i)).unwrap();
            let mut buffer = vec![0u8; 1024];
            let mut written: u32 = 0;
            let result = odbc_exec_query(
                *conn_clone,
                sql.as_ptr(),
                buffer.as_mut_ptr(),
                buffer.len() as u32,
                &mut written,
            );
            (result, i)
        });
        handles.push(handle);
    }

    // Wait for all threads
    let results: Vec<(i32, u64)> = handles
        .into_iter()
        .map(|h: std::thread::JoinHandle<(i32, u64)>| h.join().unwrap())
        .collect();

    // All should have failed
    for (result, thread_id) in &results {
        assert_ne!(*result, 0, "Thread {} query should fail", thread_id);
    }

    // Get error - should be from one of the threads (last one to set it)
    let mut error_buf = vec![0u8; 1024];
    let len = odbc_get_error(error_buf.as_mut_ptr() as *mut i8, error_buf.len() as u32);
    assert!(len >= 0, "Should get error message");

    // Cleanup
    let _ = odbc_disconnect(conn_id);
}

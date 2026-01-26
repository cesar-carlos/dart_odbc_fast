/// Concurrency tests: pool access and query execution from multiple threads.
mod helpers;
use helpers::e2e::should_run_e2e_tests;
use helpers::env::get_sqlserver_test_dsn;
use odbc_engine::pool::ConnectionPool;
use std::sync::Arc;
use std::thread;

const NUM_THREADS: usize = 4;

#[test]
#[ignore]
fn test_concurrent_pool_access() {
    if !should_run_e2e_tests() {
        eprintln!("Skipping: no ODBC DSN configured");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("DSN");
    let pool = Arc::new(ConnectionPool::new(&conn_str, NUM_THREADS as u32).expect("create pool"));

    let handles: Vec<_> = (0..NUM_THREADS)
        .map(|_| {
            let p = Arc::clone(&pool);
            thread::spawn(move || {
                let w = p.get().expect("get connection");
                let conn = w.get_connection();
                let mut stmt = conn.prepare("SELECT 1").expect("prepare");
                stmt.execute(()).expect("execute");
            })
        })
        .collect();

    for h in handles {
        h.join().expect("thread join");
    }
}

#[test]
#[ignore]
fn test_concurrent_query_execution() {
    if !should_run_e2e_tests() {
        eprintln!("Skipping: no ODBC DSN configured");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("DSN");
    let pool = Arc::new(ConnectionPool::new(&conn_str, NUM_THREADS as u32).expect("create pool"));

    let handles: Vec<_> = (0..NUM_THREADS)
        .map(|i| {
            let p = Arc::clone(&pool);
            thread::spawn(move || {
                let w = p.get().expect("get connection");
                let conn = w.get_connection();
                let sql = format!("SELECT {} AS id", i + 1);
                let mut stmt = conn.prepare(&sql).expect("prepare");
                let cur = stmt.execute(()).expect("execute");
                assert!(cur.is_some(), "thread {} should have result", i);
            })
        })
        .collect();

    for h in handles {
        h.join().expect("thread join");
    }
}

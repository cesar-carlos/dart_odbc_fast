//! E2E tests for statement handle reuse infrastructure.
//!
//! When `statement-handle-reuse` feature is enabled, verifies that:
//! - execute_query_with_cached_connection works
//! - cache metrics (hits, misses) are recorded
//!
//! Full LRU reuse is blocked by lifetime constraints (see cached_connection.rs);
//! this test validates the infrastructure.

use odbc_engine::engine::{execute_query_with_cached_connection, OdbcConnection, OdbcEnvironment};
use odbc_engine::protocol::BinaryProtocolDecoder;

mod helpers;
use helpers::e2e::should_run_e2e_tests;
use helpers::env::get_sqlserver_test_dsn;

#[test]
fn test_statement_reuse_infrastructure() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E test: SQL Server not available");
        return;
    }
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");

    let conn_arc = conn
        .get_handles()
        .lock()
        .unwrap()
        .get_connection(conn.get_connection_id())
        .expect("get connection");
    let mut odbc_conn = conn_arc.lock().unwrap();

    let sql = "SELECT 1 AS value";
    let buf1 = execute_query_with_cached_connection(&mut odbc_conn, sql).expect("first query");
    let buf2 = execute_query_with_cached_connection(&mut odbc_conn, sql).expect("second query");

    let dec1 = BinaryProtocolDecoder::parse(&buf1).expect("decode 1");
    let dec2 = BinaryProtocolDecoder::parse(&buf2).expect("decode 2");
    assert_eq!(dec1.row_count, dec2.row_count);
    assert!(dec1.row_count >= 1);

    #[cfg(feature = "statement-handle-reuse")]
    {
        let misses = odbc_conn.cache_misses();
        let hits = odbc_conn.cache_hits();
        assert!(misses >= 1, "expected cache_misses >= 1, got {}", misses);
        assert!(
            hits >= 1,
            "expected cache_hits >= 1 for repeated SQL, got {}",
            hits
        );
        assert!(
            odbc_conn.tracked_sql_entries() >= 1,
            "expected tracked_sql_entries >= 1"
        );
    }

    drop(odbc_conn);
    conn.disconnect().expect("disconnect");
}

/// E2E benchmark: repetitive prepare/execute cycles.
///
/// Run with: `cargo test test_statement_reuse_repetitive_benchmark -- --ignored --nocapture`
/// Compare with feature: `cargo test test_statement_reuse_repetitive_benchmark --features statement-handle-reuse -- --ignored --nocapture`
///
/// When LRU cache is implemented, feature-on build should show ~10%+ improvement.
/// Currently both builds perform similarly (passthrough mode).
#[test]
#[ignore = "E2E benchmark; run with --ignored when ENABLE_E2E_TESTS=1"]
fn test_statement_reuse_repetitive_benchmark() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping E2E benchmark: SQL Server not available");
        return;
    }

    const ITERATIONS: usize = 500;
    const ROUNDS: usize = 21;
    let conn_str = get_sqlserver_test_dsn().expect("Failed to build connection string");

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");

    let conn_arc = conn
        .get_handles()
        .lock()
        .unwrap()
        .get_connection(conn.get_connection_id())
        .expect("get connection");
    let mut odbc_conn = conn_arc.lock().unwrap();

    let sql = "SELECT 1 AS value";
    let mut qps_samples: Vec<f64> = Vec::with_capacity(ROUNDS);
    let mut elapsed_samples_ms: Vec<f64> = Vec::with_capacity(ROUNDS);

    for _ in 0..ROUNDS {
        let start = std::time::Instant::now();
        for _ in 0..ITERATIONS {
            let buf = execute_query_with_cached_connection(&mut odbc_conn, sql).expect("query");
            let dec = odbc_engine::protocol::BinaryProtocolDecoder::parse(&buf).expect("decode");
            assert!(dec.row_count >= 1, "expected at least 1 row");
        }
        let elapsed = start.elapsed();
        let elapsed_ms = elapsed.as_secs_f64() * 1000.0;
        let qps = ITERATIONS as f64 / elapsed.as_secs_f64();
        qps_samples.push(qps);
        elapsed_samples_ms.push(elapsed_ms);
    }

    qps_samples.sort_by(|a, b| a.partial_cmp(b).expect("valid float ordering"));
    elapsed_samples_ms.sort_by(|a, b| a.partial_cmp(b).expect("valid float ordering"));
    let n = qps_samples.len();
    let qps_avg = qps_samples.iter().sum::<f64>() / (n as f64);
    let elapsed_avg_ms = elapsed_samples_ms.iter().sum::<f64>() / (n as f64);
    let qps_median = qps_samples[n / 2];
    let elapsed_median_ms = elapsed_samples_ms[n / 2];

    let variance = qps_samples
        .iter()
        .map(|x| (x - qps_avg).powi(2))
        .sum::<f64>()
        / (n as f64);
    let qps_std = variance.sqrt();

    fn percentile(sorted: &[f64], p: f64) -> f64 {
        if sorted.is_empty() {
            return 0.0;
        }
        let idx = (p / 100.0 * (sorted.len() - 1) as f64).round() as usize;
        sorted[idx.min(sorted.len() - 1)]
    }
    let qps_p25 = percentile(&qps_samples, 25.0);
    let qps_p75 = percentile(&qps_samples, 75.0);
    let qps_p90 = percentile(&qps_samples, 90.0);

    println!(
        "statement_reuse_benchmark: rounds={}, iterations/round={}",
        ROUNDS, ITERATIONS
    );
    println!(
        "  qps: avg={:.1} median={:.1} std={:.1} p25={:.1} p75={:.1} p90={:.1}",
        qps_avg, qps_median, qps_std, qps_p25, qps_p75, qps_p90
    );
    println!(
        "  elapsed_ms: avg={:.2} median={:.2}",
        elapsed_avg_ms, elapsed_median_ms
    );

    #[cfg(feature = "statement-handle-reuse")]
    {
        let hits = odbc_conn.cache_hits();
        let misses = odbc_conn.cache_misses();
        let evictions = odbc_conn.cache_evictions();
        println!(
            "  (feature on) cache_hits={}, cache_misses={}, cache_evictions={}",
            hits, misses, evictions
        );
    }

    #[cfg(not(feature = "statement-handle-reuse"))]
    {
        println!("  (feature off) baseline");
    }

    drop(odbc_conn);
    conn.disconnect().expect("disconnect");
}

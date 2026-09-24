//! Opt-in, read-only SQL Server hot-path benchmarks using production FFI.
//!
//! Set `ODBC_LIVE_BENCH=1` and `ODBC_TEST_DSN` in the process environment.
//! The SQL only reads `sys.all_objects`; no tables are created or dropped.

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use odbc_engine::ffi::{
    odbc_connect, odbc_disconnect, odbc_exec_query, odbc_exec_query_multi, odbc_exec_query_params,
    odbc_init, odbc_pool_close, odbc_pool_create, odbc_pool_get_connection,
    odbc_pool_release_connection, odbc_stream_close, odbc_stream_fetch,
    odbc_stream_multi_start_batched, odbc_stream_start_batched, odbc_stream_start_batched_options,
    odbc_transaction_begin, odbc_transaction_commit,
};
use odbc_engine::protocol::ParamValue;
use std::ffi::CString;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};

const ROWS_100: &str = "SELECT TOP 100 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b";
const ROWS_1000: &str = "SELECT TOP 1000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b";

fn dsn() -> Option<CString> {
    if std::env::var("ODBC_LIVE_BENCH").as_deref() != Ok("1") {
        eprintln!("Skipping live_hotpaths_bench: set ODBC_LIVE_BENCH=1 explicitly");
        return None;
    }
    let value = std::env::var("ODBC_TEST_DSN").ok()?;
    CString::new(value).ok()
}

struct Connections(Vec<u32>);

impl Connections {
    fn open(dsn: &CString, count: usize) -> Self {
        assert_eq!(odbc_init(), 0, "ODBC init");
        let ids = (0..count)
            .map(|_| {
                let id = odbc_connect(dsn.as_ptr());
                assert!(id > 0, "ODBC connect");
                id
            })
            .collect();
        Self(ids)
    }
}

impl Drop for Connections {
    fn drop(&mut self) {
        for id in self.0.drain(..) {
            let _ = odbc_disconnect(id);
        }
    }
}

fn execute(conn_id: u32, sql: &CString, output: &mut [u8]) -> usize {
    let mut written = 0;
    let status = odbc_exec_query(
        conn_id,
        sql.as_ptr(),
        output.as_mut_ptr(),
        output.len() as u32,
        &mut written,
    );
    assert_eq!(status, 0, "ODBC exec");
    written as usize
}

fn bench_ffi_connections(c: &mut Criterion) {
    let Some(dsn) = dsn() else { return };
    let connections = Connections::open(&dsn, 8);
    let sql = Arc::new(CString::new(ROWS_100).expect("SQL"));
    let mut group = c.benchmark_group("live_ffi/row_major_100");
    for count in [1usize, 4, 8] {
        let ids = &connections.0[..count];
        group.bench_with_input(BenchmarkId::from_parameter(count), &count, |b, _| {
            b.iter(|| {
                std::thread::scope(|scope| {
                    let workers: Vec<_> = ids
                        .iter()
                        .map(|&id| {
                            let sql = Arc::clone(&sql);
                            scope.spawn(move || {
                                let mut output = vec![0; 1024 * 1024];
                                let mut bytes = 0;
                                for _ in 0..10 {
                                    bytes += execute(id, &sql, &mut output);
                                }
                                bytes
                            })
                        })
                        .collect();
                    let bytes: usize = workers
                        .into_iter()
                        .map(|worker| worker.join().expect("worker"))
                        .sum();
                    black_box(bytes)
                })
            });
        });
    }
    group.finish();
}

fn bench_ffi_connections_sustained(c: &mut Criterion) {
    let Some(dsn) = dsn() else { return };
    let connections = Connections::open(&dsn, 8);
    let sql = Arc::new(CString::new(ROWS_100).expect("SQL"));
    let mut group = c.benchmark_group("live_ffi/row_major_100_sustained");
    for count in [1usize, 4, 8] {
        let start = Arc::new(Barrier::new(count + 1));
        let done = Arc::new(Barrier::new(count + 1));
        let stop = Arc::new(AtomicBool::new(false));
        let bytes = Arc::new(AtomicUsize::new(0));
        let workers: Vec<_> = connections.0[..count]
            .iter()
            .map(|&id| {
                let start = Arc::clone(&start);
                let done = Arc::clone(&done);
                let stop = Arc::clone(&stop);
                let bytes = Arc::clone(&bytes);
                let sql = Arc::clone(&sql);
                std::thread::spawn(move || {
                    let mut output = vec![0; 1024 * 1024];
                    loop {
                        start.wait();
                        if stop.load(Ordering::Acquire) {
                            break;
                        }
                        let mut completed = 0;
                        for _ in 0..10 {
                            completed += execute(id, &sql, &mut output);
                        }
                        bytes.fetch_add(completed, Ordering::Relaxed);
                        done.wait();
                    }
                })
            })
            .collect();
        group.bench_with_input(BenchmarkId::from_parameter(count), &count, |b, _| {
            b.iter(|| {
                start.wait();
                done.wait();
                black_box(bytes.swap(0, Ordering::Relaxed))
            });
        });
        stop.store(true, Ordering::Release);
        start.wait();
        for worker in workers {
            worker.join().expect("worker");
        }
    }
    group.finish();
}

fn bench_pool_and_transactions(c: &mut Criterion) {
    let Some(dsn) = dsn() else { return };
    let connections = Connections::open(&dsn, 8);
    let pool_id = odbc_pool_create(dsn.as_ptr(), 8);
    assert!(pool_id > 0, "create pool");
    let sql = CString::new("SELECT 1 AS n").expect("SQL");
    let mut output = vec![0; 4096];
    let mut group = c.benchmark_group("live_ffi/pool_transaction");
    group.bench_function("checkout_checkin", |b| {
        b.iter(|| {
            let conn_id = odbc_pool_get_connection(pool_id);
            assert!(conn_id > 0, "pool checkout");
            assert_eq!(odbc_pool_release_connection(conn_id), 0, "pool checkin");
            black_box(conn_id)
        });
    });
    group.bench_function("transaction_commit", |b| {
        b.iter(|| {
            let txn_id = odbc_transaction_begin(connections.0[0], 1, 0);
            assert!(txn_id > 0, "transaction begin");
            assert_eq!(odbc_transaction_commit(txn_id), 0, "transaction commit");
            black_box(txn_id)
        });
    });
    group.bench_function("transaction_cached_query", |b| {
        b.iter(|| {
            let txn_id = odbc_transaction_begin(connections.0[0], 1, 0);
            assert!(txn_id > 0, "transaction begin");
            black_box(execute(connections.0[0], &sql, &mut output));
            assert_eq!(odbc_transaction_commit(txn_id), 0, "transaction commit");
        });
    });
    group.finish();
    assert_eq!(odbc_pool_close(pool_id), 0, "close pool");
}

fn bench_pool_transaction_sustained(c: &mut Criterion) {
    let Some(dsn) = dsn() else { return };
    let connections = Connections::open(&dsn, 8);
    let pool_id = odbc_pool_create(dsn.as_ptr(), 8);
    assert!(pool_id > 0, "create pool");
    let mut group = c.benchmark_group("live_ffi/pool_transaction_sustained");
    for count in [1usize, 4, 8] {
        for pool_workload in [true, false] {
            let start = Arc::new(Barrier::new(count + 1));
            let done = Arc::new(Barrier::new(count + 1));
            let stop = Arc::new(AtomicBool::new(false));
            let workers: Vec<_> = connections.0[..count]
                .iter()
                .map(|&conn_id| {
                    let start = Arc::clone(&start);
                    let done = Arc::clone(&done);
                    let stop = Arc::clone(&stop);
                    std::thread::spawn(move || loop {
                        start.wait();
                        if stop.load(Ordering::Acquire) {
                            break;
                        }
                        for _ in 0..10 {
                            if pool_workload {
                                let checked_out = odbc_pool_get_connection(pool_id);
                                assert!(checked_out > 0, "pool checkout");
                                assert_eq!(odbc_pool_release_connection(checked_out), 0);
                            } else {
                                let txn_id = odbc_transaction_begin(conn_id, 1, 0);
                                assert!(txn_id > 0, "transaction begin");
                                assert_eq!(odbc_transaction_commit(txn_id), 0);
                            }
                        }
                        done.wait();
                    })
                })
                .collect();
            let name = if pool_workload {
                "checkout_checkin"
            } else {
                "transaction_commit"
            };
            group.bench_function(format!("{name}_{count}"), |b| {
                b.iter(|| {
                    start.wait();
                    done.wait();
                    black_box(count * 10)
                });
            });
            stop.store(true, Ordering::Release);
            start.wait();
            for worker in workers {
                worker.join().expect("pool or transaction worker");
            }
        }
    }
    group.finish();
    assert_eq!(odbc_pool_close(pool_id), 0, "close pool");
}

fn drain_stream(conn_id: u32, sql: &CString, fetch_size: u32, columnar: bool) -> usize {
    let stream_id = if columnar {
        odbc_stream_start_batched_options(conn_id, sql.as_ptr(), fetch_size, 1024 * 1024, 2)
    } else {
        odbc_stream_start_batched(conn_id, sql.as_ptr(), fetch_size, 1024 * 1024)
    };
    fetch_stream(stream_id)
}

fn fetch_stream(stream_id: u32) -> usize {
    assert!(stream_id > 0, "start stream");
    let mut output = vec![0; 1024 * 1024];
    let mut total = 0;
    loop {
        let mut written = 0;
        let mut more = 0;
        let status = odbc_stream_fetch(
            stream_id,
            output.as_mut_ptr(),
            output.len() as u32,
            &mut written,
            &mut more,
        );
        assert_eq!(status, 0, "fetch stream");
        total += written as usize;
        if more == 0 {
            break;
        }
    }
    assert_eq!(odbc_stream_close(stream_id), 0, "close stream");
    total
}

fn bench_streaming(c: &mut Criterion) {
    let Some(dsn) = dsn() else { return };
    let connections = Connections::open(&dsn, 1);
    let mut group = c.benchmark_group("live_ffi/streaming");
    for (rows, sql_text) in [(100, ROWS_100), (1000, ROWS_1000)] {
        let sql = CString::new(sql_text).expect("SQL");
        for columnar in [false, true] {
            let name = format!("{rows}_{}", if columnar { "columnar_zstd" } else { "row" });
            group.bench_function(name, |b| {
                b.iter(|| black_box(drain_stream(connections.0[0], &sql, 100, columnar)));
            });
        }
    }
    group.finish();
}

fn bench_params_and_multi(c: &mut Criterion) {
    let Some(dsn) = dsn() else { return };
    let connections = Connections::open(&dsn, 1);
    let mut group = c.benchmark_group("live_ffi/params_multi");
    let cases = [
        (
            "numeric_null",
            "SELECT CAST(? AS INT) AS a, CAST(? AS INT) AS b",
            vec![ParamValue::Null, ParamValue::Integer(42)],
        ),
        (
            "blob_null",
            "SELECT CAST(? AS VARBINARY(8000)) AS a, CAST(? AS VARBINARY(8000)) AS b",
            vec![ParamValue::Null, ParamValue::Binary(vec![7; 4096])],
        ),
    ];
    for (name, sql_text, values) in cases {
        let sql = CString::new(sql_text).expect("SQL");
        let params: Vec<u8> = values
            .into_iter()
            .flat_map(|value| value.serialize())
            .collect();
        let mut preflight_output = vec![0; 1024 * 1024];
        let mut preflight_written = 0;
        let preflight = odbc_exec_query_params(
            connections.0[0],
            sql.as_ptr(),
            params.as_ptr(),
            params.len() as u32,
            preflight_output.as_mut_ptr(),
            preflight_output.len() as u32,
            &mut preflight_written,
        );
        if preflight != 0 {
            eprintln!("Skipping {name}: configured ODBC driver rejected the parameter fixture");
            continue;
        }
        group.bench_function(name, |b| {
            let mut output = vec![0; 1024 * 1024];
            b.iter(|| {
                let mut written = 0;
                let status = odbc_exec_query_params(
                    connections.0[0],
                    sql.as_ptr(),
                    params.as_ptr(),
                    params.len() as u32,
                    output.as_mut_ptr(),
                    output.len() as u32,
                    &mut written,
                );
                assert_eq!(status, 0, "parameterized exec");
                black_box(written)
            });
        });
    }
    let sql = CString::new("SELECT 1 AS a; SELECT 2 AS b").expect("SQL");
    group.bench_function("multi_repeated", |b| {
        let mut output = vec![0; 1024 * 1024];
        b.iter(|| {
            let mut written = 0;
            let status = odbc_exec_query_multi(
                connections.0[0],
                sql.as_ptr(),
                output.as_mut_ptr(),
                output.len() as u32,
                &mut written,
            );
            assert_eq!(status, 0, "MULT exec");
            black_box(written)
        });
    });
    group.bench_function("multi_stream_repeated", |b| {
        b.iter(|| {
            let stream_id = odbc_stream_multi_start_batched(connections.0[0], sql.as_ptr(), 4096);
            black_box(fetch_stream(stream_id))
        });
    });
    group.finish();
}

criterion_group!(
    benches,
    bench_ffi_connections,
    bench_ffi_connections_sustained,
    bench_pool_and_transactions,
    bench_pool_transaction_sustained,
    bench_streaming,
    bench_params_and_multi
);
criterion_main!(benches);

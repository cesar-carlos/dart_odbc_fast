//! Synthetic FFI contention bench.
//!
//! Models the lock pattern used by the FFI layer:
//!
//! - **monolithic**: one `Mutex` for connections + errors + metrics +
//!   statements + pool busy counts (historical layout).
//! - **sharded**: dedicated locks per category — matches the production
//!   split where connections, errors, metrics, metadata cache, streams,
//!   statements, and pools live outside the residual `GlobalState` mutex.
//!
//! No ODBC required — we model only the synchronisation primitives.
//!
//! Run:
//!
//! ```text
//! cargo bench --bench ffi_contention_bench
//! ```

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};
use std::thread;
use std::time::Duration;

const ITERATIONS_PER_THREAD: usize = 1_000;
const THREAD_COUNTS: &[usize] = &[1, 2, 4, 8];

/// Mirrors the historical layout: every category lives inside one mutex.
struct MonolithicState {
    connections: HashMap<u32, u32>,
    errors: HashMap<u32, String>,
    statements: HashMap<u32, u32>,
    pooled_busy: HashMap<u32, usize>,
    metrics: u64,
}

/// Mirrors the current production layout after the pools split:
/// per-category locks; pooled busy-count bumps no longer contend with
/// statement or connection traffic.
struct ShardedState {
    connections: RwLock<HashMap<u32, u32>>,
    errors: Mutex<HashMap<u32, String>>,
    statements: Mutex<HashMap<u32, u32>>,
    pools: Mutex<HashMap<u32, usize>>,
    metrics: std::sync::atomic::AtomicU64,
}

fn run_monolithic(state: Arc<Mutex<MonolithicState>>, threads: usize) {
    let mut handles = Vec::with_capacity(threads);
    for thread_idx in 0..threads {
        let state = Arc::clone(&state);
        handles.push(thread::spawn(move || {
            for i in 0..ITERATIONS_PER_THREAD {
                let conn_id = (thread_idx as u32) * 1000 + (i as u32);
                let stmt_id = conn_id.wrapping_add(10_000);
                let pool_id = (thread_idx as u32) + 1;

                // Mixed traffic: connection lookup + pool busy bump +
                // statement insert + error write.
                {
                    let mut guard = state.lock().expect("lock");
                    let _ = black_box(guard.connections.get(&conn_id).copied());
                    *guard.pooled_busy.entry(pool_id).or_insert(0) += 1;
                    guard.statements.insert(stmt_id, conn_id);
                    guard.errors.insert(conn_id, format!("ok:{i}"));
                    guard.metrics = guard.metrics.wrapping_add(1);
                }

                thread::yield_now();

                {
                    let mut guard = state.lock().expect("lock");
                    let _ = black_box(guard.statements.get(&stmt_id).copied());
                    guard.statements.remove(&stmt_id);
                    if let Some(count) = guard.pooled_busy.get_mut(&pool_id) {
                        *count = count.saturating_sub(1);
                    }
                }
            }
        }));
    }
    for h in handles {
        h.join().expect("thread");
    }
}

fn run_sharded(state: Arc<ShardedState>, threads: usize) {
    use std::sync::atomic::Ordering;

    let mut handles = Vec::with_capacity(threads);
    for thread_idx in 0..threads {
        let state = Arc::clone(&state);
        handles.push(thread::spawn(move || {
            for i in 0..ITERATIONS_PER_THREAD {
                let conn_id = (thread_idx as u32) * 1000 + (i as u32);
                let stmt_id = conn_id.wrapping_add(10_000);
                let pool_id = (thread_idx as u32) + 1;

                {
                    let guard = state.connections.read().expect("rlock");
                    let _ = black_box(guard.get(&conn_id).copied());
                }
                {
                    let mut guard = state.pools.lock().expect("pool lock");
                    *guard.entry(pool_id).or_insert(0) += 1;
                }
                {
                    let mut guard = state.statements.lock().expect("stmt lock");
                    guard.insert(stmt_id, conn_id);
                }
                {
                    let mut guard = state.errors.lock().expect("err lock");
                    guard.insert(conn_id, format!("ok:{i}"));
                }
                state.metrics.fetch_add(1, Ordering::Relaxed);

                thread::yield_now();

                {
                    let mut guard = state.statements.lock().expect("stmt lock");
                    let _ = black_box(guard.get(&stmt_id).copied());
                    guard.remove(&stmt_id);
                }
                {
                    let mut guard = state.pools.lock().expect("pool lock");
                    if let Some(count) = guard.get_mut(&pool_id) {
                        *count = count.saturating_sub(1);
                    }
                }
            }
        }));
    }
    for h in handles {
        h.join().expect("thread");
    }
}

fn bench_monolithic_contention(c: &mut Criterion) {
    let mut group = c.benchmark_group("ffi_contention/monolithic_mutex");
    group.measurement_time(Duration::from_secs(5));
    group.sample_size(20);
    for &threads in THREAD_COUNTS {
        group.bench_with_input(
            BenchmarkId::from_parameter(threads),
            &threads,
            |b, &threads| {
                b.iter(|| {
                    let state = Arc::new(Mutex::new(MonolithicState {
                        connections: HashMap::new(),
                        errors: HashMap::new(),
                        statements: HashMap::new(),
                        pooled_busy: HashMap::new(),
                        metrics: 0,
                    }));
                    run_monolithic(state, threads);
                });
            },
        );
    }
    group.finish();
}

fn bench_sharded_contention(c: &mut Criterion) {
    let mut group = c.benchmark_group("ffi_contention/sharded_per_category");
    group.measurement_time(Duration::from_secs(5));
    group.sample_size(20);
    for &threads in THREAD_COUNTS {
        group.bench_with_input(
            BenchmarkId::from_parameter(threads),
            &threads,
            |b, &threads| {
                b.iter(|| {
                    let state = Arc::new(ShardedState {
                        connections: RwLock::new(HashMap::new()),
                        errors: Mutex::new(HashMap::new()),
                        statements: Mutex::new(HashMap::new()),
                        pools: Mutex::new(HashMap::new()),
                        metrics: std::sync::atomic::AtomicU64::new(0),
                    });
                    run_sharded(state, threads);
                });
            },
        );
    }
    group.finish();
}

criterion_group!(
    benches,
    bench_monolithic_contention,
    bench_sharded_contention,
);
criterion_main!(benches);

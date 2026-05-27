//! Synthetic FFI contention bench.
//!
//! Simulates the lock pattern the current `ffi::mod` uses: a single
//! `Mutex<GlobalState>` taken twice per query
//! (`take_runnable_connection` plus `write_connection_output_buffer`)
//! versus a hypothetical sharded layout where reads of per-id maps and
//! writes of per-connection errors live in independent locks.
//!
//! No ODBC required — we model only the synchronisation primitives so the
//! sprint 3 implementation can measure its delta on this same bench.
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

/// Mirrors the production layout: every category lives inside one mutex.
struct MonolithicState {
    connections: HashMap<u32, u32>,
    errors: HashMap<u32, String>,
    metrics: u64,
}

/// Mirrors the target layout after sprint 3: per-category locks; reads of
/// the connections map can proceed while another thread is updating an
/// unrelated category.
struct ShardedState {
    connections: RwLock<HashMap<u32, u32>>,
    errors: Mutex<HashMap<u32, String>>,
    // metrics moves out of the mutex entirely — atomic in production; we
    // model that with a single AtomicU64 for fidelity.
    metrics: std::sync::atomic::AtomicU64,
}

fn run_monolithic(state: Arc<Mutex<MonolithicState>>, threads: usize) {
    let mut handles = Vec::with_capacity(threads);
    for thread_idx in 0..threads {
        let state = Arc::clone(&state);
        handles.push(thread::spawn(move || {
            for i in 0..ITERATIONS_PER_THREAD {
                let conn_id = (thread_idx as u32) * 1000 + (i as u32);

                // "take_runnable_connection": lock + read + drop.
                {
                    let guard = state.lock().expect("lock");
                    let _ = black_box(guard.connections.get(&conn_id).copied());
                }

                // Simulate the per-query work outside the lock (no-op).
                thread::yield_now();

                // "write_connection_output_buffer": lock + write + drop.
                {
                    let mut guard = state.lock().expect("lock");
                    guard.errors.insert(conn_id, format!("ok:{i}"));
                    guard.metrics = guard.metrics.wrapping_add(1);
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

                // Read-only access to connections via RwLock.
                {
                    let guard = state.connections.read().expect("rlock");
                    let _ = black_box(guard.get(&conn_id).copied());
                }

                thread::yield_now();

                // Errors only contends with other error writers.
                {
                    let mut guard = state.errors.lock().expect("err lock");
                    guard.insert(conn_id, format!("ok:{i}"));
                }

                // Metrics is fully lock-free.
                state.metrics.fetch_add(1, Ordering::Relaxed);
            }
        }));
    }
    for h in handles {
        h.join().expect("thread");
    }
}

fn bench_monolithic_contention(c: &mut Criterion) {
    let mut group = c.benchmark_group("ffi_contention/monolithic_mutex");
    // Keep wall-clock bounded; this bench spawns real threads.
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

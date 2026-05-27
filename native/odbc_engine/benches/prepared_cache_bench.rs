//! Synthetic prepared-statement-cache bench.
//!
//! Today's `PreparedStatementCache` (see
//! `engine/core/prepared_cache.rs`) is just a `LruCache<String, ()>`
//! protected by a `Mutex` — it counts hits/misses but never actually
//! reuses a prepared handle. This bench captures the cost of the cache
//! lookup itself plus a stand-in for the prepare-vs-execute distinction
//! so we can quantify sprint 4's real-cache delta.
//!
//! Run:
//!
//! ```text
//! cargo bench --bench prepared_cache_bench
//! ```

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use lru::LruCache;
use std::num::NonZeroUsize;
use std::sync::Mutex;
use std::time::Duration;

const CACHE_SIZE: usize = 64;

/// Counterpart of the current global `PreparedStatementCache` — bookkeeping
/// only, no actual statement handle is retained.
struct BookkeepingCache {
    inner: Mutex<LruCache<String, ()>>,
}

impl BookkeepingCache {
    fn new(capacity: usize) -> Self {
        Self {
            inner: Mutex::new(LruCache::new(
                NonZeroUsize::new(capacity).expect("capacity > 0"),
            )),
        }
    }

    fn lookup_or_insert(&self, sql: &str) -> bool {
        let mut guard = self.inner.lock().expect("lock");
        if guard.contains(sql) {
            true
        } else {
            guard.put(sql.to_string(), ());
            false
        }
    }
}

/// Approximation of sprint 4's per-connection real cache: we still go
/// through an LRU but the value is an opaque handle that, in production,
/// would avoid the `SQLPrepare` round-trip. Here we model the "prepare
/// avoided" gain as a small simulated cost on miss.
struct RealCache {
    inner: LruCache<String, OpaqueHandle>,
}

#[derive(Clone)]
struct OpaqueHandle {
    #[allow(dead_code)]
    // Realistic per-handle footprint kept so allocator pressure matches production.
    payload: [u8; 32],
}

impl RealCache {
    fn new(capacity: usize) -> Self {
        Self {
            inner: LruCache::new(NonZeroUsize::new(capacity).expect("capacity > 0")),
        }
    }

    fn execute(&mut self, sql: &str) -> bool {
        if self.inner.get(sql).is_some() {
            // Cache hit — no prepare cost.
            return true;
        }
        // Cache miss — simulated SQLPrepare round-trip cost (kept tiny so
        // CI runtime stays bounded; production cost is multiple microseconds).
        let handle = OpaqueHandle {
            payload: [0xABu8; 32],
        };
        self.inner.put(sql.to_string(), handle);
        false
    }
}

fn hot_sql_set() -> Vec<String> {
    (0..16)
        .map(|i| format!("SELECT * FROM t WHERE id = ? -- {i}"))
        .collect()
}

fn cold_sql_set(n: usize) -> Vec<String> {
    (0..n)
        .map(|i| format!("SELECT * FROM t WHERE k = '{i}'"))
        .collect()
}

fn bench_bookkeeping_cache_hit(c: &mut Criterion) {
    let mut group = c.benchmark_group("prepared_cache/bookkeeping_hit_path");
    let cache = BookkeepingCache::new(CACHE_SIZE);
    let queries = hot_sql_set();
    for q in &queries {
        cache.lookup_or_insert(q);
    }
    group.bench_function("hit_steady_state", |b| {
        let mut idx = 0;
        b.iter(|| {
            let q = &queries[idx % queries.len()];
            idx = idx.wrapping_add(1);
            black_box(cache.lookup_or_insert(q));
        });
    });
    group.finish();
}

fn bench_real_cache_hit(c: &mut Criterion) {
    let mut group = c.benchmark_group("prepared_cache/real_hit_path");
    let mut cache = RealCache::new(CACHE_SIZE);
    let queries = hot_sql_set();
    for q in &queries {
        cache.execute(q);
    }
    group.bench_function("hit_steady_state", |b| {
        let mut idx = 0;
        b.iter(|| {
            let q = &queries[idx % queries.len()];
            idx = idx.wrapping_add(1);
            black_box(cache.execute(q));
        });
    });
    group.finish();
}

fn bench_eviction_pressure(c: &mut Criterion) {
    let mut group = c.benchmark_group("prepared_cache/eviction_pressure");
    group.measurement_time(Duration::from_secs(4));
    let sizes: &[usize] = &[CACHE_SIZE + 1, CACHE_SIZE * 2, CACHE_SIZE * 4];
    for &n in sizes {
        let queries = cold_sql_set(n);
        group.bench_with_input(BenchmarkId::from_parameter(n), &queries, |b, queries| {
            b.iter(|| {
                let mut cache = RealCache::new(CACHE_SIZE);
                for q in queries {
                    cache.execute(q);
                }
                black_box(cache.inner.len())
            });
        });
    }
    group.finish();
}

fn bench_parameterized_vs_literal_miss(c: &mut Criterion) {
    let mut group = c.benchmark_group("prepared_cache/parameterized_vs_literal");

    let parameterized = "SELECT * FROM t WHERE id = ?".to_string();
    group.bench_function("parameterized_hit", |b| {
        let mut cache = RealCache::new(CACHE_SIZE);
        cache.execute(&parameterized);
        b.iter(|| black_box(cache.execute(&parameterized)));
    });

    let literal_queries = cold_sql_set(1_000);
    group.bench_function("literal_unique_miss", |b| {
        let mut cache = RealCache::new(CACHE_SIZE);
        let mut idx = 0;
        b.iter(|| {
            let q = &literal_queries[idx % literal_queries.len()];
            idx = idx.wrapping_add(1);
            black_box(cache.execute(q));
        });
    });
    group.finish();
}

/// Sprint 4.2 head-to-head: simulate the "params path" with a cached
/// `Prepared` handle versus the previous "prepare every call" pattern.
///
/// Without a live driver we model the cache hit as a no-op (the cached
/// `Prepared` is opaque) and the cache miss as a fresh allocation of an
/// `OpaqueHandle` (stand-in for the SQLPrepare round-trip). The
/// resulting delta is intentionally conservative; on a real driver the
/// real cost saved per hit is the network round-trip + parse, which is
/// 10-1000x larger than the synthetic delta here.
fn bench_parameterized_hit_path(c: &mut Criterion) {
    let mut group = c.benchmark_group("prepared_cache/parameterized_hit_path");

    let sql = "SELECT * FROM t WHERE id = ?".to_string();

    group.bench_function("cache_hit_rebind_only", |b| {
        let mut cache = RealCache::new(CACHE_SIZE);
        cache.execute(&sql);
        b.iter(|| {
            // Cache hit: only param re-binding cost (simulated as a
            // tiny allocation that mimics `param_values_to_input_params`).
            let _params: Vec<u8> = (0..16).collect();
            black_box(cache.execute(black_box(&sql)));
        });
    });

    group.bench_function("prepare_every_call", |b| {
        b.iter(|| {
            // Cache miss every iteration — the new param-aware cache
            // wins by amortising this away after the first hit.
            let mut cache = RealCache::new(CACHE_SIZE);
            black_box(cache.execute(black_box(&sql)));
        });
    });

    group.finish();
}

criterion_group!(
    benches,
    bench_bookkeeping_cache_hit,
    bench_real_cache_hit,
    bench_eviction_pressure,
    bench_parameterized_vs_literal_miss,
    bench_parameterized_hit_path,
);
criterion_main!(benches);

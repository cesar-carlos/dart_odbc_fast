use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use odbc_engine::engine::core::metadata_cache::{ColumnMetadata, MetadataCache, TableSchema};
use std::time::{Duration, Instant};

fn benchmark_cache_hit_vs_miss(c: &mut Criterion) {
    let cache = MetadataCache::new(100, Duration::from_secs(300));

    // Pre-populate the cache
    for i in 0..50 {
        let key = format!("conn:table_{}", i);
        let schema = TableSchema {
            table_name: format!("table_{}", i),
            columns: vec![
                ColumnMetadata {
                    name: "id".to_string(),
                    odbc_type: 4,
                    nullable: false,
                },
                ColumnMetadata {
                    name: "name".to_string(),
                    odbc_type: 12,
                    nullable: true,
                },
            ],
            cached_at: Instant::now(),
        };
        cache.cache_schema(&key, schema);
    }

    let mut group = c.benchmark_group("cache_hit_vs_miss");

    // Benchmark cache hit (entry exists)
    group.bench_function("cache_hit", |b| {
        b.iter(|| black_box(cache.get_schema("conn:table_0")));
    });

    // Benchmark cache miss (entry does not exist)
    group.bench_function("cache_miss", |b| {
        b.iter(|| black_box(cache.get_schema("conn:nonexistent_table")));
    });

    group.finish();
}

fn benchmark_cache_payload_operations(c: &mut Criterion) {
    let cache = MetadataCache::new(100, Duration::from_secs(300));

    // Pre-populate with payloads of varying sizes
    for i in 0..50 {
        let key = format!("conn:payload_{}", i);
        let data: Vec<u8> = (0..100).map(|j| (i + j) as u8).collect();
        cache.cache_payload(&key, &data);
    }

    let mut group = c.benchmark_group("payload_operations");

    // Benchmark payload cache hit
    group.bench_function("payload_hit", |b| {
        b.iter(|| black_box(cache.get_payload("conn:payload_0")));
    });

    // Benchmark payload cache miss
    group.bench_function("payload_miss", |b| {
        b.iter(|| black_box(cache.get_payload("conn:nonexistent")));
    });

    // Benchmark payload insert
    group.bench_function("payload_insert", |b| {
        let mut counter = 1000u32;
        b.iter(|| {
            let key = format!("conn:new_payload_{}", counter);
            let data = vec![1u8, 2, 3, 4, 5];
            cache.cache_payload(&key, &data);
            counter += 1;
            black_box(())
        });
    });

    group.finish();
}

fn benchmark_cache_scaling(c: &mut Criterion) {
    let mut group = c.benchmark_group("cache_scaling");

    // Test cache performance with different sizes
    for size in [10, 50, 100, 500].iter() {
        let cache = MetadataCache::new(*size, Duration::from_secs(300));

        // Fill cache to 80% capacity
        let fill_count = (*size as f64 * 0.8) as usize;
        for i in 0..fill_count {
            let key = format!("conn:table_{}", i);
            let schema = TableSchema {
                table_name: format!("table_{}", i),
                columns: vec![ColumnMetadata {
                    name: "id".to_string(),
                    odbc_type: 4,
                    nullable: false,
                }],
                cached_at: Instant::now(),
            };
            cache.cache_schema(&key, schema);
        }

        group.bench_with_input(BenchmarkId::new("get_schema", size), size, |b, _| {
            b.iter(|| {
                // Access a mix of cached entries
                for i in 0..10.min(fill_count) {
                    black_box(cache.get_schema(&format!("conn:table_{}", i)));
                }
            });
        });
    }

    group.finish();
}

fn benchmark_stats_and_clear(c: &mut Criterion) {
    let cache = MetadataCache::new(100, Duration::from_secs(300));

    // Pre-populate
    for i in 0..50 {
        let key = format!("conn:table_{}", i);
        let schema = TableSchema {
            table_name: format!("table_{}", i),
            columns: vec![],
            cached_at: Instant::now(),
        };
        cache.cache_schema(&key, schema);
    }

    let mut group = c.benchmark_group("stats_and_clear");

    group.bench_function("stats", |b| {
        b.iter(|| black_box(cache.stats()));
    });

    // Note: We don't benchmark clear in a loop because it would empty the cache
    group.bench_function("clear_once", |b| {
        b.iter(|| {
            let test_cache = MetadataCache::new(100, Duration::from_secs(300));
            for i in 0..10 {
                test_cache.cache_payload(&format!("key_{}", i), &[1, 2, 3]);
            }
            test_cache.clear();
            black_box(test_cache.stats())
        });
    });

    group.finish();
}

/// Benchmark demonstrating cache effectiveness for repeated queries.
/// Shows the performance difference between:
/// 1. Cold cache (first query)
/// 2. Warm cache (subsequent queries)
fn benchmark_repeated_query_simulation(c: &mut Criterion) {
    let cache = MetadataCache::new(100, Duration::from_secs(300));

    let mut group = c.benchmark_group("repeated_query_simulation");

    // Simulate 100 repeated queries to the same 10 tables
    group.bench_function("100_queries_10_tables", |b| {
        b.iter(|| {
            for query_num in 0..100 {
                let table_idx = query_num % 10;
                let key = format!("conn:table_{}", table_idx);

                // Check cache first
                if cache.get_schema(&key).is_none() {
                    // Simulate "query" and cache result
                    let schema = TableSchema {
                        table_name: format!("table_{}", table_idx),
                        columns: vec![
                            ColumnMetadata {
                                name: "id".to_string(),
                                odbc_type: 4,
                                nullable: false,
                            },
                            ColumnMetadata {
                                name: "data".to_string(),
                                odbc_type: 12,
                                nullable: true,
                            },
                        ],
                        cached_at: Instant::now(),
                    };
                    cache.cache_schema(&key, schema);
                }
            }
            black_box(())
        });
    });

    group.finish();
}

criterion_group!(
    benches,
    benchmark_cache_hit_vs_miss,
    benchmark_cache_payload_operations,
    benchmark_cache_scaling,
    benchmark_stats_and_clear,
    benchmark_repeated_query_simulation,
);
criterion_main!(benches);

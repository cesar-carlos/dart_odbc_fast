use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use odbc_engine::engine::core::metadata_cache::{ColumnMetadata, MetadataCache, TableSchema};
use std::time::{Duration, Instant};

fn small_schema(i: usize) -> TableSchema {
    TableSchema {
        table_name: format!("table_{i}"),
        columns: vec![ColumnMetadata {
            name: "id".to_string(),
            odbc_type: 4,
            nullable: false,
        }],
        cached_at: Instant::now(),
    }
}

fn benchmark_cache_hit_vs_miss(c: &mut Criterion) {
    let cache = MetadataCache::new(100, Duration::from_secs(300));

    for i in 0..50 {
        let key = format!("conn:table_{i}");
        let schema = TableSchema {
            table_name: format!("table_{i}"),
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

    let hit_key = "conn:table_0".to_string();
    let miss_key = "conn:nonexistent_table".to_string();

    let mut group = c.benchmark_group("cache_hit_vs_miss");

    group.bench_function("cache_hit", |b| {
        b.iter(|| black_box(cache.get_schema_shared_for_benchmark(hit_key.as_str())));
    });

    group.bench_function("cache_miss", |b| {
        b.iter(|| black_box(cache.get_schema_shared_for_benchmark(miss_key.as_str())));
    });

    group.finish();
}

fn benchmark_cache_payload_operations(c: &mut Criterion) {
    let cache = MetadataCache::new(100, Duration::from_secs(300));

    let payload_keys: Vec<String> = (0..50).map(|i| format!("conn:payload_{i}")).collect();
    for (i, key) in payload_keys.iter().enumerate() {
        let data: Vec<u8> = (0..100).map(|j| (i + j) as u8).collect();
        cache.cache_payload(key, &data);
    }

    let hit_key = payload_keys[0].clone();
    let miss_key = "conn:nonexistent".to_string();

    let mut group = c.benchmark_group("payload_operations");

    group.bench_function("payload_hit", |b| {
        b.iter(|| black_box(cache.get_payload_shared_for_benchmark(hit_key.as_str())));
    });

    group.bench_function("payload_miss", |b| {
        b.iter(|| black_box(cache.get_payload_shared_for_benchmark(miss_key.as_str())));
    });

    let rotation_keys: Vec<String> = (0..200).map(|i| format!("conn:payload_rot_{i}")).collect();
    let data = vec![1u8, 2, 3, 4, 5];
    let mut rot = 0usize;
    group.bench_function("payload_insert_steady", |b| {
        b.iter(|| {
            let key = &rotation_keys[rot % rotation_keys.len()];
            rot = rot.wrapping_add(1);
            cache.cache_payload(key, &data);
            black_box(cache.get_payload_shared_for_benchmark(key));
        });
    });

    group.finish();
}

fn benchmark_cache_scaling(c: &mut Criterion) {
    let mut group = c.benchmark_group("cache_scaling");

    for size in [10, 50, 100, 500].iter() {
        let cache = MetadataCache::new(*size, Duration::from_secs(300));

        let fill_count = (*size as f64 * 0.8) as usize;
        let keys: Vec<String> = (0..fill_count).map(|i| format!("conn:table_{i}")).collect();
        for (i, key) in keys.iter().enumerate() {
            cache.cache_schema(key, small_schema(i));
        }

        let lookups = (*size).max(10);
        let lookup_indices: Vec<usize> = (0..lookups)
            .map(|i| (i * 7 + 3) % fill_count.max(1))
            .collect();

        group.bench_with_input(BenchmarkId::new("get_schema", size), size, |b, _| {
            b.iter(|| {
                for &idx in &lookup_indices {
                    black_box(cache.get_schema_shared_for_benchmark(keys[idx].as_str()));
                }
            });
        });
    }

    group.finish();
}

fn benchmark_payload_scaling(c: &mut Criterion) {
    let mut group = c.benchmark_group("payload_scaling");

    for size in [10, 50, 100, 500].iter() {
        let cache = MetadataCache::new(*size, Duration::from_secs(300));
        let fill_count = (*size as f64 * 0.8) as usize;
        let keys: Vec<String> = (0..fill_count).map(|i| format!("42:Produto:{i}")).collect();
        for (i, key) in keys.iter().enumerate() {
            let data: Vec<u8> = (0..64).map(|j| ((i + j) % 256) as u8).collect();
            cache.cache_payload(key, &data);
        }
        let lookups = (*size).max(10);
        let lookup_indices: Vec<usize> = (0..lookups)
            .map(|i| (i * 11 + 5) % fill_count.max(1))
            .collect();

        group.bench_with_input(BenchmarkId::new("get_payload", size), size, |b, _| {
            b.iter(|| {
                for &idx in &lookup_indices {
                    black_box(cache.get_payload_shared_for_benchmark(keys[idx].as_str()));
                }
            });
        });
    }

    group.finish();
}

fn benchmark_eviction_at_capacity(c: &mut Criterion) {
    let mut group = c.benchmark_group("cache_eviction");
    let capacity = 500usize;
    let keys: Vec<String> = (0..capacity).map(|i| format!("conn:table_{i}")).collect();
    let cache = MetadataCache::new(capacity, Duration::from_secs(300));
    for (i, key) in keys.iter().enumerate() {
        cache.cache_schema(key, small_schema(i));
    }

    group.bench_function("get_schema_mid_at_capacity", |b| {
        b.iter(|| black_box(cache.get_schema_shared_for_benchmark(keys[250].as_str())));
    });

    group.bench_function("insert_then_get_overflow_key", |b| {
        let overflow_key = "conn:table_overflow";
        b.iter(|| {
            cache.cache_schema(overflow_key, small_schema(999_999));
            black_box(cache.get_schema_shared_for_benchmark(overflow_key));
        });
    });

    group.finish();
}

fn benchmark_stats_and_clear(c: &mut Criterion) {
    let cache = MetadataCache::new(100, Duration::from_secs(300));

    for i in 0..50 {
        let key = format!("conn:table_{i}");
        let schema = TableSchema {
            table_name: format!("table_{i}"),
            columns: vec![],
            cached_at: Instant::now(),
        };
        cache.cache_schema(&key, schema);
    }

    let mut group = c.benchmark_group("stats_and_clear");

    group.bench_function("stats", |b| {
        b.iter(|| black_box(cache.stats()));
    });

    group.bench_function("clear_once", |b| {
        b.iter(|| {
            let test_cache = MetadataCache::new(100, Duration::from_secs(300));
            for i in 0..10 {
                test_cache.cache_payload(&format!("key_{i}"), &[1, 2, 3]);
            }
            test_cache.clear();
            black_box(test_cache.stats())
        });
    });

    group.finish();
}

fn benchmark_repeated_query_simulation(c: &mut Criterion) {
    let cache = MetadataCache::new(100, Duration::from_secs(300));

    let mut group = c.benchmark_group("repeated_query_simulation");

    group.bench_function("100_queries_10_tables", |b| {
        b.iter(|| {
            for query_num in 0..100 {
                let table_idx = query_num % 10;
                let key = format!("conn:table_{table_idx}");

                if cache.get_schema_shared_for_benchmark(&key).is_none() {
                    let schema = TableSchema {
                        table_name: format!("table_{table_idx}"),
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
    benchmark_payload_scaling,
    benchmark_eviction_at_capacity,
    benchmark_stats_and_clear,
    benchmark_repeated_query_simulation,
);
criterion_main!(benches);

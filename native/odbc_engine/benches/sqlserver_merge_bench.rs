use criterion::{criterion_group, criterion_main, Criterion};
use odbc_engine::plugins::{sqlserver::SqlServerPlugin, Upsertable};
use std::hint::black_box;

fn benchmark(c: &mut Criterion) {
    let plugin = SqlServerPlugin::new();
    let mut group = c.benchmark_group("sqlserver_merge");
    for width in [1, 8, 128] {
        let names: Vec<_> = (0..width).map(|i| format!("col_{i}")).collect();
        let columns: Vec<_> = names.iter().map(String::as_str).collect();
        let build = || {
            plugin
                .build_upsert_sql("dbo.items", black_box(&columns), &["col_0"], None)
                .expect("valid MERGE")
        };
        let sql = build();
        assert_eq!(sql.matches('?').count(), width);
        assert_eq!(sql.contains("WHEN MATCHED THEN UPDATE"), width > 1);
        group.bench_function(width.to_string(), |b| b.iter(|| black_box(build())));
    }
    group.finish();
}

criterion_group!(benches, benchmark);
criterion_main!(benches);

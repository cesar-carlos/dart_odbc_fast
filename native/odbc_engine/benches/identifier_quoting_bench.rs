use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use odbc_engine::engine::{quote_identifier_default, quote_qualified_default};
use odbc_engine::Result;

// Historical implementation from 9a6e367 for a same-build comparison.
fn baseline(qualified: &str) -> Result<String> {
    let parts: Vec<&str> = qualified.split('.').collect();
    let mut quoted_parts = Vec::with_capacity(parts.len());
    for part in parts {
        quoted_parts.push(quote_identifier_default(part)?);
    }
    Ok(quoted_parts.join("."))
}

fn benchmark(c: &mut Criterion) {
    let mut group = c.benchmark_group("qualified_identifier");
    for (name, input) in [
        ("one", "users".to_owned()),
        ("two", "public.users".to_owned()),
        ("three", "catalog.public.users".to_owned()),
        ("long", format!("{}.{}", "s".repeat(128), "t".repeat(128))),
        ("many", vec!["segment"; 16].join(".")),
    ] {
        assert_eq!(
            baseline(&input).expect("baseline"),
            quote_qualified_default(&input).expect("candidate")
        );
        group.bench_with_input(BenchmarkId::new("baseline", name), &input, |b, input| {
            b.iter(|| black_box(baseline(black_box(input)).expect("valid")));
        });
        group.bench_with_input(BenchmarkId::new("candidate", name), &input, |b, input| {
            b.iter(|| black_box(quote_qualified_default(black_box(input)).expect("valid")));
        });
    }
    group.finish();
}

criterion_group!(benches, benchmark);
criterion_main!(benches);

//! Placeholder bench for columnar v2 — anchors the `columnar-v2` feature and
//! gives a place to add row-major vs columnar A/B tests later.
//!
//! Run: `cargo bench --bench columnar_v2_placeholder --features columnar-v2`

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use odbc_engine::protocol::columnar_v2::{COLUMNAR_V2_MAGIC, COLUMNAR_V2_VERSION};

fn bench_header_constants(c: &mut Criterion) {
    c.bench_function("columnar_v2_magic_black_box", |b| {
        b.iter(|| black_box(COLUMNAR_V2_MAGIC))
    });
    c.bench_function("columnar_v2_version_black_box", |b| {
        b.iter(|| black_box(COLUMNAR_V2_VERSION))
    });
}

criterion_group!(benches, bench_header_constants);
criterion_main!(benches);

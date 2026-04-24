//! Row-major (v1) vs columnar (v2) encoding throughput — Criterion.
//!
//! Run: `cargo bench --bench columnar_v1_v2_encode`
//!
//! Compares `RowBufferEncoder` (v1) with `ColumnarEncoder` on the same logical
//! table, with/without per-column zstd, after `row_buffer_to_columnar`.

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use odbc_engine::protocol::{
    row_buffer_to_columnar, ColumnarEncoder, OdbcType, RowBuffer, RowBufferEncoder,
};

fn make_fixture(rows: usize, cols: usize) -> RowBuffer {
    let mut rb = RowBuffer::new();
    for c in 0..cols {
        rb.add_column(format!("c{c}"), OdbcType::Varchar);
    }
    for r in 0..rows {
        let mut row = Vec::with_capacity(cols);
        for c in 0..cols {
            // ~24+ bytes per cell so the columnar payload is not tiny.
            let s = format!("r{r:05}c{c:03}....................");
            row.push(Some(s.into_bytes()));
        }
        rb.add_row(row);
    }
    rb
}

fn columnar_v1_v2_benches(c: &mut Criterion) {
    let mut group = c.benchmark_group("encode_row_vs_columnar");
    for (rows, cols) in [(256usize, 16usize), (1024, 32)] {
        let rb = make_fixture(rows, cols);
        let colbuf = row_buffer_to_columnar(&rb);
        let v1 = RowBufferEncoder::encode(&rb);
        let len = v1.len() as u64;
        group.throughput(Throughput::Bytes(len));
        let id = format!("r{rows}_c{cols}_bytes_{len}");
        group.bench_function(BenchmarkId::new("v1_row_major", &id), |b| {
            b.iter(|| {
                let out = RowBufferEncoder::encode(black_box(&rb));
                black_box(out);
            });
        });
        group.bench_function(BenchmarkId::new("v2_columnar_nocompress", &id), |b| {
            b.iter(|| {
                let out = ColumnarEncoder::encode(black_box(&colbuf), false).expect("encode");
                black_box(out);
            });
        });
        group.bench_function(BenchmarkId::new("v2_columnar_zstd", &id), |b| {
            b.iter(|| {
                let out = ColumnarEncoder::encode(black_box(&colbuf), true).expect("encode");
                black_box(out);
            });
        });
    }
    group.finish();
}

criterion_group!(benches, columnar_v1_v2_benches);
criterion_main!(benches);

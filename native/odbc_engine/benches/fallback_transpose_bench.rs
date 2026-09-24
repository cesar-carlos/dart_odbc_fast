//! Compare the production one-shot and reusable row-to-column transposition.

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use odbc_engine::protocol::{ColumnarEncoder, OdbcType, RowBuffer};

mod error {
    pub use odbc_engine::{OdbcError, Result};
}

mod protocol {
    pub use odbc_engine::protocol::{columnar, row_buffer, types};
}

#[path = "../src/protocol/converter.rs"]
mod converter;

fn fixture(rows: usize) -> RowBuffer {
    let mut source = RowBuffer::new();
    source.add_column("id".to_string(), OdbcType::Integer);
    source.add_column("payload".to_string(), OdbcType::Binary);
    for index in 0..rows {
        source.add_row_vecs(vec![
            Some((index as i32).to_le_bytes().to_vec()),
            (index % 5 != 0).then(|| vec![index as u8; 128]),
        ]);
    }
    source
}

fn bench_fallback_transpose(c: &mut Criterion) {
    let mut group = c.benchmark_group("fallback_transpose_16_batches");
    for rows in [100usize, 1000] {
        let source = fixture(rows);
        group.bench_with_input(BenchmarkId::new("fresh", rows), &source, |b, source| {
            b.iter(|| {
                let mut bytes = 0;
                for _ in 0..16 {
                    let v2 = converter::row_buffer_to_columnar(black_box(source.clone()))
                        .expect("transpose");
                    bytes += ColumnarEncoder::encode(&v2, false).expect("encode").len();
                }
                black_box(bytes);
            });
        });
        group.bench_with_input(BenchmarkId::new("reused", rows), &source, |b, source| {
            let mut v2 = converter::empty_columnar_for_row_buffer(source);
            b.iter(|| {
                let mut bytes = 0;
                for _ in 0..16 {
                    let mut batch = black_box(source.clone());
                    converter::transpose_row_buffer_into(&mut batch, &mut v2).expect("transpose");
                    bytes += ColumnarEncoder::encode(&v2, false).expect("encode").len();
                }
                black_box(bytes);
            });
        });
    }
    group.finish();
}

criterion_group!(benches, bench_fallback_transpose);
criterion_main!(benches);

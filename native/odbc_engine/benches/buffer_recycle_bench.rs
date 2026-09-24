//! Measure the production chunk-copy helper with fresh and recycled buffers.
//! No ODBC driver is needed; both cases copy the same encoded payload bytes.

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};

mod error {
    pub use odbc_engine::{OdbcError, Result};
}

#[path = "../src/engine/streaming/chunk.rs"]
mod chunk;

fn bench_buffer_recycling(c: &mut Criterion) {
    let mut sample = Some(vec![1u8]);
    let mut sample_offset = 0;
    black_box(chunk::current_batch_len(&sample));
    black_box(
        chunk::take_current_batch_chunk(&mut sample, &mut sample_offset, 1, "missing", None)
            .expect("owned chunk"),
    );
    black_box(chunk::StreamCopyResult::End);
    let mut group = c.benchmark_group("stream_buffer_copy");
    for size in [64 * 1024usize, 1024 * 1024] {
        let payload = vec![42u8; size];
        let mut output = vec![0u8; size + 5];
        group.bench_with_input(BenchmarkId::new("fresh", size), &payload, |b, payload| {
            b.iter(|| {
                let mut encoded = Vec::new();
                encoded.extend_from_slice(&[0; 5]);
                encoded.extend_from_slice(black_box(payload));
                let mut batch = Some(encoded);
                let mut offset = 0;
                black_box(
                    chunk::copy_current_batch_chunk(
                        &mut batch,
                        &mut offset,
                        payload.len() + 5,
                        &mut output,
                        true,
                        "missing",
                        None,
                    )
                    .expect("copy"),
                );
            });
        });
        let pool = chunk::BatchBufferPool::default();
        group.bench_with_input(
            BenchmarkId::new("recycled", size),
            &payload,
            |b, payload| {
                b.iter(|| {
                    let mut encoded = pool.take();
                    encoded.extend_from_slice(&[0; 5]);
                    encoded.extend_from_slice(black_box(payload));
                    let mut batch = Some(encoded);
                    let mut offset = 0;
                    black_box(
                        chunk::copy_current_batch_chunk(
                            &mut batch,
                            &mut offset,
                            payload.len() + 5,
                            &mut output,
                            true,
                            "missing",
                            Some(&pool),
                        )
                        .expect("copy"),
                    );
                });
            },
        );
    }
    group.finish();
}

criterion_group!(benches, bench_buffer_recycling);
criterion_main!(benches);

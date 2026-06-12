use criterion::{black_box, criterion_group, criterion_main, BatchSize, BenchmarkId, Criterion};
use odbc_engine::engine::core::ArrayBinding;
use odbc_engine::engine::{StreamCopyResult, StreamingState};
use odbc_engine::protocol::types::OdbcType;
use odbc_engine::protocol::{RowBuffer, RowBufferEncoder};

fn benchmark_array_binding_new(c: &mut Criterion) {
    c.bench_function("array_binding_new_1000", |b| {
        b.iter(|| {
            let ab = ArrayBinding::new(black_box(1000));
            black_box(ab.paramset_size())
        });
    });
}

fn benchmark_encode_empty_buffer(c: &mut Criterion) {
    let buffer = RowBuffer::new();
    c.bench_function("encode_empty_buffer", |b| {
        b.iter(|| black_box(RowBufferEncoder::encode(black_box(&buffer)).expect("encode")));
    });
}

fn benchmark_encode_small_buffer(c: &mut Criterion) {
    let mut buffer = RowBuffer::new();
    buffer.add_column("id".to_string(), OdbcType::Integer);
    buffer.add_column("name".to_string(), OdbcType::Varchar);
    for i in 0i32..100 {
        buffer.add_row(vec![
            Some(i.to_le_bytes().to_vec()),
            Some(format!("user_{}", i).into_bytes()),
        ]);
    }
    c.bench_function("encode_small_buffer_100_rows", |b| {
        b.iter(|| black_box(RowBufferEncoder::encode(black_box(&buffer)).expect("encode")));
    });
}

fn benchmark_encode_with_compression(c: &mut Criterion) {
    let mut buffer = RowBuffer::new();
    buffer.add_column("id".to_string(), OdbcType::Integer);
    buffer.add_column("name".to_string(), OdbcType::Varchar);
    for i in 0i32..1000 {
        buffer.add_row(vec![
            Some(i.to_le_bytes().to_vec()),
            Some(format!("user_{}", i).into_bytes()),
        ]);
    }
    c.bench_function("encode_with_compression_1000_rows", |b| {
        b.iter(|| {
            black_box(RowBufferEncoder::encode_with_compression(black_box(
                &buffer,
            )))
        });
    });
}

fn benchmark_streaming_copy_next_chunk(c: &mut Criterion) {
    let payload: Vec<u8> = (0..(1024 * 1024)).map(|i| (i % 251) as u8).collect();
    let mut group = c.benchmark_group("streaming_copy_next_chunk");

    for chunk_size in [4 * 1024usize, 64 * 1024] {
        group.bench_with_input(
            BenchmarkId::new("in_memory", chunk_size),
            &chunk_size,
            |b, &chunk_size| {
                b.iter_batched(
                    || StreamingState::from_bytes_for_benchmark(payload.clone(), chunk_size),
                    |mut state| {
                        let mut out = vec![0u8; chunk_size];
                        let mut total = 0usize;
                        loop {
                            match state
                                .copy_next_chunk(black_box(out.as_mut_slice()))
                                .expect("stream copy should succeed")
                            {
                                StreamCopyResult::Copied { written, .. } => {
                                    total += written;
                                }
                                StreamCopyResult::End => break,
                                StreamCopyResult::BufferTooSmall { needed } => {
                                    panic!("unexpected small benchmark buffer: {needed}");
                                }
                            }
                        }
                        black_box(total)
                    },
                    BatchSize::LargeInput,
                );
            },
        );
    }

    group.finish();
}

criterion_group!(
    benches,
    benchmark_array_binding_new,
    benchmark_encode_empty_buffer,
    benchmark_encode_small_buffer,
    benchmark_encode_with_compression,
    benchmark_streaming_copy_next_chunk,
);
criterion_main!(benches);

use criterion::{black_box, criterion_group, criterion_main, BatchSize, BenchmarkId, Criterion};
use odbc_engine::engine::core::ArrayBinding;
use odbc_engine::engine::{StreamCopyResult, StreamingState};
use odbc_engine::protocol::types::OdbcType;
use odbc_engine::protocol::{
    try_encode_multi, MultiResultItem, MultiResultWriter, RowBuffer, RowBufferEncoder,
};

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
        buffer.add_row_vecs(vec![
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
        buffer.add_row_vecs(vec![
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

/// A/B: old collect-then-`try_encode_multi` path vs in-place [`MultiResultWriter`].
///
/// Both arms start from the same owned result-set payloads. The writer avoids the
/// intermediate `Vec<MultiResultItem>` and the capacity pre-scan.
fn benchmark_multi_result_writer_vs_encode(c: &mut Criterion) {
    let shapes: &[(usize, usize)] = &[(8, 4 * 1024), (32, 64 * 1024), (128, 16 * 1024)];
    let mut group = c.benchmark_group("multi_result_writer_vs_encode");

    for &(item_count, payload_len) in shapes {
        let payloads: Vec<Vec<u8>> = (0..item_count)
            .map(|i| {
                let mut buf = vec![0u8; payload_len];
                for (j, byte) in buf.iter_mut().enumerate() {
                    *byte = ((i * 131 + j) % 251) as u8;
                }
                buf
            })
            .collect();
        let id = format!("{item_count}x{payload_len}");

        group.bench_with_input(
            BenchmarkId::new("collect_then_try_encode", &id),
            &payloads,
            |b, payloads| {
                b.iter(|| {
                    let items: Vec<MultiResultItem> = payloads
                        .iter()
                        .map(|p| MultiResultItem::ResultSet(p.clone()))
                        .chain(std::iter::once(MultiResultItem::RowCount(42)))
                        .collect();
                    black_box(try_encode_multi(&items).expect("encode"))
                });
            },
        );

        group.bench_with_input(
            BenchmarkId::new("multi_result_writer", &id),
            &payloads,
            |b, payloads| {
                b.iter(|| {
                    let mut writer = MultiResultWriter::new();
                    if let Some(first) = payloads.first() {
                        writer.reserve_similar(first.len(), payloads.len().saturating_sub(1));
                    }
                    for payload in payloads {
                        writer
                            .push_result_set(payload.clone())
                            .expect("push result set");
                    }
                    writer.push_row_count(42).expect("push row count");
                    black_box(writer.finish().expect("finish"))
                });
            },
        );
    }

    group.finish();
}

/// A/B for FFI stream copy when the Dart output buffer is larger than the
/// configured `chunk_size` (the case fixed by limiting copy to `out.len()`).
///
/// **KPI is FFI round count**, not isolated memcpy wall time. In production
/// Dart usually passes `bufferSize == chunkSize` (both default 64 KiB), so the
/// paths are equivalent; this bench forces a mismatch (`chunk_size=4KiB`,
/// `out=64KiB`) to show the round-trip reduction (64 → 4). Larger per-call
/// memcpy can look slower in Criterion while still winning end-to-end because
/// each Dart↔native poll is far more expensive than the copy itself.
fn benchmark_stream_copy_chunk_vs_out_capacity(c: &mut Criterion) {
    let batch: Vec<u8> = (0..(256 * 1024)).map(|i| (i % 251) as u8).collect();
    let chunk_size = 4 * 1024usize;
    let out_capacity = 64 * 1024usize;
    let mut group = c.benchmark_group("stream_copy_chunk_vs_out_capacity");
    group.throughput(criterion::Throughput::Bytes(batch.len() as u64));

    group.bench_function("limit_by_chunk_size", |b| {
        b.iter_batched(
            || (batch.clone(), vec![0u8; out_capacity]),
            |(batch, mut out)| {
                let mut offset = 0usize;
                let mut total = 0usize;
                let mut ffi_rounds = 0usize;
                while offset < batch.len() {
                    let end = offset.saturating_add(chunk_size).min(batch.len());
                    let needed = end - offset;
                    out[..needed].copy_from_slice(&batch[offset..end]);
                    black_box(&out[..needed]);
                    offset = end;
                    total += needed;
                    ffi_rounds += 1;
                }
                // Expected: 256KiB / 4KiB = 64 rounds vs 4 with out.len().
                assert_eq!(ffi_rounds, 64);
                black_box((total, ffi_rounds))
            },
            BatchSize::LargeInput,
        );
    });

    group.bench_function("limit_by_out_len", |b| {
        b.iter_batched(
            || (batch.clone(), vec![0u8; out_capacity]),
            |(batch, mut out)| {
                let mut offset = 0usize;
                let mut total = 0usize;
                let mut ffi_rounds = 0usize;
                while offset < batch.len() {
                    let end = offset.saturating_add(out.len()).min(batch.len());
                    let needed = end - offset;
                    out[..needed].copy_from_slice(&batch[offset..end]);
                    black_box(&out[..needed]);
                    offset = end;
                    total += needed;
                    ffi_rounds += 1;
                }
                // Expected: 256KiB / 64KiB = 4 rounds vs 64 with 4KiB chunks.
                assert_eq!(ffi_rounds, 4);
                black_box((total, ffi_rounds))
            },
            BatchSize::LargeInput,
        );
    });

    group.finish();
}

criterion_group!(
    benches,
    benchmark_array_binding_new,
    benchmark_encode_empty_buffer,
    benchmark_encode_small_buffer,
    benchmark_encode_with_compression,
    benchmark_streaming_copy_next_chunk,
    benchmark_multi_result_writer_vs_encode,
    benchmark_stream_copy_chunk_vs_out_capacity,
);
criterion_main!(benches);

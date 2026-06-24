//! Micro-benches isolating the cell decode / row-buffer build cost.
//!
//! These benches do not require an ODBC driver. They synthesise the wire-shape
//! input that `CellReader` would produce (UTF-16 → UTF-8 bytes for text,
//! little-endian `i32` / `i64` payloads for integers, raw bytes for binary)
//! and benchmark the downstream encoding work that follows the fetch.
//!
//! Goal: provide a stable signal for the perf sprints 1-2 (block-cursor fetch
//! and columnar direct fetch) so we can compare apples-to-apples deltas
//! without depending on a live SQL Server. Run:
//!
//! ```text
//! cargo bench --bench cell_reader_bench
//! ```

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use odbc_engine::protocol::{OdbcType, RowBuffer, RowBufferEncoder};

const ROW_COUNTS: &[usize] = &[100, 1_000, 10_000];

fn build_int_buffer(rows: usize) -> RowBuffer {
    let mut buf = RowBuffer::new();
    buf.add_column("id".to_string(), OdbcType::Integer);
    for i in 0..rows {
        buf.add_row_vecs(vec![Some((i as i32).to_le_bytes().to_vec())]);
    }
    buf
}

fn build_bigint_buffer(rows: usize) -> RowBuffer {
    let mut buf = RowBuffer::new();
    buf.add_column("big_id".to_string(), OdbcType::BigInt);
    for i in 0..rows {
        buf.add_row_vecs(vec![Some((i as i64 * 1_000_003).to_le_bytes().to_vec())]);
    }
    buf
}

fn build_varchar_buffer(rows: usize, value: &[u8]) -> RowBuffer {
    let mut buf = RowBuffer::new();
    buf.add_column("name".to_string(), OdbcType::Varchar);
    for _ in 0..rows {
        buf.add_row_vecs(vec![Some(value.to_vec())]);
    }
    buf
}

fn build_binary_buffer(rows: usize, payload: &[u8]) -> RowBuffer {
    let mut buf = RowBuffer::new();
    buf.add_column("payload".to_string(), OdbcType::Binary);
    for _ in 0..rows {
        buf.add_row_vecs(vec![Some(payload.to_vec())]);
    }
    buf
}

fn bench_encode_int_only(c: &mut Criterion) {
    let mut group = c.benchmark_group("cell_reader/encode_int_only");
    for &rows in ROW_COUNTS {
        let buf = build_int_buffer(rows);
        group.bench_with_input(BenchmarkId::from_parameter(rows), &buf, |b, buf| {
            b.iter(|| black_box(RowBufferEncoder::encode_result(buf).expect("encode")));
        });
    }
    group.finish();
}

fn bench_encode_bigint_only(c: &mut Criterion) {
    let mut group = c.benchmark_group("cell_reader/encode_bigint_only");
    for &rows in ROW_COUNTS {
        let buf = build_bigint_buffer(rows);
        group.bench_with_input(BenchmarkId::from_parameter(rows), &buf, |b, buf| {
            b.iter(|| black_box(RowBufferEncoder::encode_result(buf).expect("encode")));
        });
    }
    group.finish();
}

fn bench_encode_varchar_short(c: &mut Criterion) {
    let mut group = c.benchmark_group("cell_reader/encode_varchar_short");
    for &rows in ROW_COUNTS {
        let buf = build_varchar_buffer(rows, b"Alice in Wonderland");
        group.bench_with_input(BenchmarkId::from_parameter(rows), &buf, |b, buf| {
            b.iter(|| black_box(RowBufferEncoder::encode_result(buf).expect("encode")));
        });
    }
    group.finish();
}

fn bench_encode_binary_small(c: &mut Criterion) {
    let mut group = c.benchmark_group("cell_reader/encode_binary_small");
    let payload = vec![0xABu8; 256];
    for &rows in ROW_COUNTS {
        let buf = build_binary_buffer(rows, &payload);
        group.bench_with_input(BenchmarkId::from_parameter(rows), &buf, |b, buf| {
            b.iter(|| black_box(RowBufferEncoder::encode_result(buf).expect("encode")));
        });
    }
    group.finish();
}

/// Approximates the wide-text → UTF-8 conversion the cell reader performs on
/// every non-numeric, non-binary cell. Sprint 0 captures this so sprint 1 can
/// quantify the BlockCursor savings on text-heavy workloads.
fn bench_wide_text_to_utf8(c: &mut Criterion) {
    let mut group = c.benchmark_group("cell_reader/wide_text_to_utf8");
    let lengths: &[usize] = &[8, 64, 512, 4096];
    for &len in lengths {
        let ascii_wide: Vec<u16> = (0..len as u16).map(|i| b'A' as u16 + (i % 26)).collect();
        group.bench_with_input(BenchmarkId::from_parameter(len), &ascii_wide, |b, wide| {
            b.iter(|| {
                let s = String::from_utf16_lossy(black_box(wide));
                black_box(s.into_bytes())
            });
        });
    }
    group.finish();
}

fn build_date_buffer(rows: usize) -> RowBuffer {
    let mut buf = RowBuffer::new();
    buf.add_column("event_date".to_string(), OdbcType::Date);
    for _ in 0..rows {
        buf.add_row_vecs(vec![Some(b"2026-05-27".to_vec())]);
    }
    buf
}

fn build_timestamp_buffer(rows: usize) -> RowBuffer {
    let mut buf = RowBuffer::new();
    buf.add_column("event_ts".to_string(), OdbcType::Timestamp);
    for _ in 0..rows {
        buf.add_row_vecs(vec![Some(b"2026-05-27 12:34:56.789000".to_vec())]);
    }
    buf
}

/// Sprint 4 follow-up B5: encoded-bytes throughput for temporal
/// columns. The native temporal path in `block_fetch` formats the
/// driver-returned `Date`/`Timestamp` structs directly into these
/// bytes; this bench measures the downstream encoder cost so PR2.2's
/// gain can be isolated from upstream fetch noise.
fn bench_encode_date_only(c: &mut Criterion) {
    let mut group = c.benchmark_group("cell_reader/encode_date_only");
    for &rows in ROW_COUNTS {
        let buf = build_date_buffer(rows);
        group.bench_with_input(BenchmarkId::from_parameter(rows), &buf, |b, buf| {
            b.iter(|| black_box(RowBufferEncoder::encode_result(buf).expect("encode")));
        });
    }
    group.finish();
}

fn bench_encode_timestamp_only(c: &mut Criterion) {
    let mut group = c.benchmark_group("cell_reader/encode_timestamp_only");
    for &rows in ROW_COUNTS {
        let buf = build_timestamp_buffer(rows);
        group.bench_with_input(BenchmarkId::from_parameter(rows), &buf, |b, buf| {
            b.iter(|| black_box(RowBufferEncoder::encode_result(buf).expect("encode")));
        });
    }
    group.finish();
}

criterion_group!(
    benches,
    bench_encode_int_only,
    bench_encode_bigint_only,
    bench_encode_varchar_short,
    bench_encode_binary_small,
    bench_wide_text_to_utf8,
    bench_encode_date_only,
    bench_encode_timestamp_only,
);
criterion_main!(benches);

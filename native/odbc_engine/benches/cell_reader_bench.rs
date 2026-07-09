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
/// every non-numeric, non-binary cell. Compares the legacy
/// `String::from_utf16_lossy` path against the shared ASCII fast-path in
/// [`odbc_engine::engine::wide_text`].
fn bench_wide_text_to_utf8(c: &mut Criterion) {
    use odbc_engine::engine::wide_text::{wide_text_to_utf8_bytes, wide_text_to_utf8_vec};

    let mut group = c.benchmark_group("cell_reader/wide_text_to_utf8");
    let lengths: &[usize] = &[8, 64, 512, 4096];
    for &len in lengths {
        let ascii_wide: Vec<u16> = (0..len as u16).map(|i| b'A' as u16 + (i % 26)).collect();
        group.bench_with_input(
            BenchmarkId::new("legacy_lossy", len),
            &ascii_wide,
            |b, wide| {
                b.iter(|| {
                    let s = String::from_utf16_lossy(black_box(wide));
                    black_box(s.into_bytes())
                });
            },
        );
        group.bench_with_input(
            BenchmarkId::new("ascii_fast_vec", len),
            &ascii_wide,
            |b, wide| {
                b.iter(|| black_box(wide_text_to_utf8_vec(black_box(wide))));
            },
        );
        group.bench_with_input(
            BenchmarkId::new("ascii_fast_cell", len),
            &ascii_wide,
            |b, wide| {
                b.iter(|| black_box(wide_text_to_utf8_bytes(black_box(wide))));
            },
        );
    }

    // Non-ASCII regression arm: ensure the lossy fallback stays competitive
    // (no accidental slowdown vs the previous always-lossy path).
    let cjk_wide: Vec<u16> = "你好世界テストデータ"
        .encode_utf16()
        .cycle()
        .take(512)
        .collect();
    group.bench_function("legacy_lossy/cjk_512", |b| {
        b.iter(|| {
            let s = String::from_utf16_lossy(black_box(&cjk_wide));
            black_box(s.into_bytes())
        });
    });
    group.bench_function("ascii_fast_vec/cjk_512", |b| {
        b.iter(|| black_box(wide_text_to_utf8_vec(black_box(&cjk_wide))));
    });
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

/// A/B for the block-fetch temporal materialisation path.
///
/// `legacy_string_clone` mirrors the pre-change implementation
/// (`String` format buffer + `scratch.clone()` into the cell).
/// `direct_move` mirrors the current path (`write!` into `Vec<u8>` +
/// move into `CellBytes`). Comparing the two arms on identical inputs
/// quantifies the allocation/memcpy savings without a live ODBC driver.
fn bench_temporal_format_materialise(c: &mut Criterion) {
    use odbc_engine::engine::core::block_fetch::{
        format_date_into, format_time_into, format_timestamp_into,
    };
    use odbc_engine::protocol::CellBytes;

    let date = odbc_api::sys::Date {
        year: 2026,
        month: 5,
        day: 27,
    };
    let time = odbc_api::sys::Time {
        hour: 12,
        minute: 34,
        second: 56,
    };
    let ts = odbc_api::sys::Timestamp {
        year: 2026,
        month: 5,
        day: 27,
        hour: 12,
        minute: 34,
        second: 56,
        fraction: 789_000_000,
    };

    let mut group = c.benchmark_group("cell_reader/temporal_format_materialise");
    for &rows in ROW_COUNTS {
        group.bench_with_input(
            BenchmarkId::new("legacy_string_clone/date", rows),
            &rows,
            |b, &rows| {
                b.iter(|| {
                    let mut out: Vec<CellBytes> = Vec::with_capacity(rows);
                    let mut scratch = Vec::with_capacity(10);
                    for _ in 0..rows {
                        // Old path: format via String, copy into scratch, clone.
                        let mut s = String::with_capacity(10);
                        use std::fmt::Write as _;
                        let _ = write!(s, "{:04}-{:02}-{:02}", date.year, date.month, date.day);
                        scratch.clear();
                        scratch.extend_from_slice(s.as_bytes());
                        out.push(scratch.clone().into());
                    }
                    black_box(out)
                });
            },
        );
        group.bench_with_input(
            BenchmarkId::new("direct_move/date", rows),
            &rows,
            |b, &rows| {
                b.iter(|| {
                    let mut out: Vec<CellBytes> = Vec::with_capacity(rows);
                    for _ in 0..rows {
                        let mut bytes = Vec::with_capacity(10);
                        format_date_into(&mut bytes, &date);
                        out.push(bytes.into());
                    }
                    black_box(out)
                });
            },
        );
        group.bench_with_input(
            BenchmarkId::new("legacy_string_clone/time", rows),
            &rows,
            |b, &rows| {
                b.iter(|| {
                    let mut out: Vec<CellBytes> = Vec::with_capacity(rows);
                    let mut scratch = Vec::with_capacity(8);
                    for _ in 0..rows {
                        let mut s = String::with_capacity(8);
                        use std::fmt::Write as _;
                        let _ = write!(s, "{:02}:{:02}:{:02}", time.hour, time.minute, time.second);
                        scratch.clear();
                        scratch.extend_from_slice(s.as_bytes());
                        out.push(scratch.clone().into());
                    }
                    black_box(out)
                });
            },
        );
        group.bench_with_input(
            BenchmarkId::new("direct_move/time", rows),
            &rows,
            |b, &rows| {
                b.iter(|| {
                    let mut out: Vec<CellBytes> = Vec::with_capacity(rows);
                    for _ in 0..rows {
                        let mut bytes = CellBytes::new();
                        format_time_into(&mut bytes, &time);
                        out.push(bytes);
                    }
                    black_box(out)
                });
            },
        );
        group.bench_with_input(
            BenchmarkId::new("legacy_string_clone/timestamp", rows),
            &rows,
            |b, &rows| {
                b.iter(|| {
                    let mut out: Vec<CellBytes> = Vec::with_capacity(rows);
                    let mut scratch = Vec::with_capacity(26);
                    for _ in 0..rows {
                        let mut s = String::with_capacity(26);
                        use std::fmt::Write as _;
                        let micros = ts.fraction / 1_000;
                        let _ = write!(
                            s,
                            "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:06}",
                            ts.year, ts.month, ts.day, ts.hour, ts.minute, ts.second, micros
                        );
                        scratch.clear();
                        scratch.extend_from_slice(s.as_bytes());
                        out.push(scratch.clone().into());
                    }
                    black_box(out)
                });
            },
        );
        group.bench_with_input(
            BenchmarkId::new("direct_move/timestamp", rows),
            &rows,
            |b, &rows| {
                b.iter(|| {
                    let mut out: Vec<CellBytes> = Vec::with_capacity(rows);
                    for _ in 0..rows {
                        let mut bytes = Vec::with_capacity(26);
                        format_timestamp_into(&mut bytes, &ts);
                        out.push(bytes.into());
                    }
                    black_box(out)
                });
            },
        );
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
    bench_temporal_format_materialise,
);
criterion_main!(benches);

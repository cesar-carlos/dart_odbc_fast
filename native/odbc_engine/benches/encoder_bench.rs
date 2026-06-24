//! Synthetic encoder benches covering row-major and columnar paths.
//!
//! Run:
//!
//! ```text
//! cargo bench --bench encoder_bench
//! ```
//!
//! The same dataset is fed into:
//!
//! 1. `RowBufferEncoder::encode_result` (current row-major path).
//! 2. `row_buffer_to_columnar` + `ColumnarEncoder::encode` (current
//!    "columnar" path — the transposition cost is what sprint 2 aims to
//!    eliminate by populating `ColumnData` directly from the cursor).
//!
//! Comparing the two arms on identical inputs gives us the headroom for
//! sprint 2's "direct columnar fetch" change.

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use odbc_engine::protocol::{
    columnar::{ColumnData, ColumnMetadata, RowBufferV2},
    row_buffer_to_columnar, ColumnarEncoder, OdbcType, RowBuffer, RowBufferEncoder,
};

const SHAPES: &[(usize, usize)] = &[
    (1_000, 1),
    (1_000, 10),
    (10_000, 10),
    (100_000, 1),
    (100_000, 10),
    (10_000, 50),
];

fn build_mixed_buffer(rows: usize, cols: usize) -> RowBuffer {
    let mut buf = RowBuffer::new();
    for c in 0..cols {
        let (name, t) = match c % 4 {
            0 => (format!("int_{c}"), OdbcType::Integer),
            1 => (format!("big_{c}"), OdbcType::BigInt),
            2 => (format!("name_{c}"), OdbcType::Varchar),
            _ => (format!("bin_{c}"), OdbcType::Binary),
        };
        buf.add_column(name, t);
    }

    for r in 0..rows {
        let mut row = Vec::with_capacity(cols);
        for c in 0..cols {
            let cell = match c % 4 {
                0 => Some((r as i32).to_le_bytes().to_vec()),
                1 => Some((r as i64 * 1_000_003).to_le_bytes().to_vec()),
                2 => Some(format!("row_{r}_col_{c}").into_bytes()),
                _ => Some(vec![r as u8; 32]),
            };
            row.push(cell);
        }
        buf.add_row_vecs(row);
    }
    buf
}

fn bench_row_major_encode(c: &mut Criterion) {
    let mut group = c.benchmark_group("encoder/row_major");
    for &(rows, cols) in SHAPES {
        let buf = build_mixed_buffer(rows, cols);
        let id = format!("{rows}x{cols}");
        group.bench_with_input(BenchmarkId::from_parameter(id), &buf, |b, buf| {
            b.iter(|| black_box(RowBufferEncoder::encode_result(buf).expect("encode")));
        });
    }
    group.finish();
}

fn bench_columnar_via_row_major(c: &mut Criterion) {
    let mut group = c.benchmark_group("encoder/columnar_via_row_major");
    for &(rows, cols) in SHAPES {
        let buf = build_mixed_buffer(rows, cols);
        let id = format!("{rows}x{cols}");
        group.bench_with_input(BenchmarkId::from_parameter(id), &buf, |b, buf| {
            b.iter(|| {
                let v2 = row_buffer_to_columnar(buf.clone()).expect("convert");
                black_box(ColumnarEncoder::encode(&v2, false).expect("encode"))
            });
        });
    }
    group.finish();
}

fn bench_columnar_via_row_major_compressed(c: &mut Criterion) {
    let mut group = c.benchmark_group("encoder/columnar_via_row_major_compressed");
    // Skip the very small shapes — compression overhead dominates and we
    // already benchmark its no-op fast path in the uncompressed group.
    for &(rows, cols) in SHAPES.iter().filter(|(r, _)| *r >= 10_000) {
        let buf = build_mixed_buffer(rows, cols);
        let id = format!("{rows}x{cols}");
        group.bench_with_input(BenchmarkId::from_parameter(id), &buf, |b, buf| {
            b.iter(|| {
                let v2 = row_buffer_to_columnar(buf.clone()).expect("convert");
                black_box(ColumnarEncoder::encode(&v2, true).expect("encode"))
            });
        });
    }
    group.finish();
}

/// Pure transposition cost — what sprint 2 eliminates by populating
/// `ColumnData` straight from the cursor.
fn bench_row_to_columnar_conversion(c: &mut Criterion) {
    let mut group = c.benchmark_group("encoder/row_to_columnar_conversion");
    for &(rows, cols) in SHAPES {
        let buf = build_mixed_buffer(rows, cols);
        let id = format!("{rows}x{cols}");
        group.bench_with_input(BenchmarkId::from_parameter(id), &buf, |b, buf| {
            b.iter(|| black_box(row_buffer_to_columnar(buf.clone()).expect("convert")));
        });
    }
    group.finish();
}

/// Build a `RowBufferV2` directly with the same shape and data as
/// [`build_mixed_buffer`] would produce. This is the column-major mirror
/// of the row-major builder: the data is laid out the way sprint 2's
/// `columnar_fetch::fetch_columnar_into` would land it from a real
/// cursor, *without* the row-major intermediate or its `.clone()`
/// surcharge in the converter.
fn build_mixed_v2(rows: usize, cols: usize) -> RowBufferV2 {
    let mut v2 = RowBufferV2::with_capacity(cols);
    v2.set_row_count(rows);
    for c in 0..cols {
        let (name, data) = match c % 4 {
            0 => {
                let mut col_data = Vec::with_capacity(rows);
                for r in 0..rows {
                    col_data.push(Some(r as i32));
                }
                (format!("int_{c}"), ColumnData::Integer(col_data))
            }
            1 => {
                let mut col_data = Vec::with_capacity(rows);
                for r in 0..rows {
                    col_data.push(Some(r as i64 * 1_000_003));
                }
                (format!("big_{c}"), ColumnData::BigInt(col_data))
            }
            2 => {
                let mut col_data = Vec::with_capacity(rows);
                for r in 0..rows {
                    col_data.push(Some(format!("row_{r}_col_{c}").into_bytes()));
                }
                (format!("name_{c}"), ColumnData::Varchar(col_data))
            }
            _ => {
                let mut col_data = Vec::with_capacity(rows);
                for r in 0..rows {
                    col_data.push(Some(vec![r as u8; 32]));
                }
                (format!("bin_{c}"), ColumnData::Binary(col_data))
            }
        };
        let odbc_type = match c % 4 {
            0 => OdbcType::Integer,
            1 => OdbcType::BigInt,
            2 => OdbcType::Varchar,
            _ => OdbcType::Binary,
        };
        v2.add_column(ColumnMetadata { name, odbc_type }, data);
    }
    v2
}

/// Head-to-head sprint 2 comparison: row-major + transpose + encode vs.
/// direct column-major + encode (no intermediate). Same input bytes end
/// up in `ColumnarEncoder::encode` either way, so the delta isolates
/// exactly the transposition cost the new fetch path skips.
fn bench_direct_columnar_vs_via_row_major(c: &mut Criterion) {
    let mut group = c.benchmark_group("encoder/direct_columnar_vs_via_row_major");
    for &(rows, cols) in SHAPES {
        let id = format!("{rows}x{cols}");

        let row_major = build_mixed_buffer(rows, cols);
        let v2 = build_mixed_v2(rows, cols);

        group.bench_with_input(
            BenchmarkId::new("via_row_major_then_transpose", &id),
            &row_major,
            |b, buf| {
                b.iter(|| {
                    let v2 = row_buffer_to_columnar(buf.clone()).expect("convert");
                    black_box(ColumnarEncoder::encode(&v2, false).expect("encode"))
                });
            },
        );

        group.bench_with_input(BenchmarkId::new("direct_v2_encode", &id), &v2, |b, v2| {
            b.iter(|| black_box(ColumnarEncoder::encode(v2, false).expect("encode")));
        });
    }
    group.finish();
}

/// Simulates streaming columnar batches: each batch is a `RowBufferV2` slice
/// (as produced by `ColumnarStreamingSession::fetch_next_batch_v2`) encoded
/// independently — the path batched streaming takes when `result_encoding`
/// is columnar and `plan_buffer_descs` succeeds.
fn bench_streaming_columnar_batch_encode(c: &mut Criterion) {
    let batch_rows = 100usize;
    let cols = 10usize;
    let batches = 100usize;

    let mut group = c.benchmark_group("encoder/streaming_columnar_batch");
    group.bench_function(format!("{batches}x{batch_rows}x{cols}"), |b| {
        let batch_v2 = build_mixed_v2(batch_rows, cols);
        b.iter(|| {
            let mut total = 0usize;
            for _ in 0..batches {
                total +=
                    black_box(ColumnarEncoder::encode(&batch_v2, false).expect("encode")).len();
            }
            black_box(total)
        });
    });
    group.finish();
}

criterion_group!(
    benches,
    bench_row_major_encode,
    bench_columnar_via_row_major,
    bench_columnar_via_row_major_compressed,
    bench_row_to_columnar_conversion,
    bench_direct_columnar_vs_via_row_major,
    bench_streaming_columnar_batch_encode,
);
criterion_main!(benches);

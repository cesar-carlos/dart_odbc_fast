//! Paired comparison of the scratch reserve, using identical payload writers.
//! Run with `cargo run --release --example compression_paired_bench` from native/.

pub mod error {
    pub use odbc_engine::{OdbcError, Result};
}
pub mod protocol {
    pub use odbc_engine::protocol::*;
}
pub mod encoder {
    include!("../src/protocol/columnar_encoder.rs");

    /// The pre-reserve orchestration. All framing, payload and compression
    /// helpers are shared with production to isolate the allocation change.
    pub fn encode_without_scratch_seed(buffer: &RowBufferV2, compressed: bool) -> Result<Vec<u8>> {
        let columns = checked_u16(buffer.column_count(), "column count")?;
        let rows = checked_u32(buffer.row_count, "row count")?;
        let mut output = Vec::new();
        if !compressed {
            ColumnarEncoder::encode_uncompressed_into(&mut output, buffer, columns, rows)?;
            return Ok(output);
        }
        for column in &buffer.columns {
            checked_u16(column.metadata.name.len(), "column name length")?;
        }
        output.reserve(HEADER_SIZE + COMPRESSED_INITIAL_PAYLOAD_RESERVE_BYTES);
        let (position, start) =
            ColumnarEncoder::write_header(&mut output, buffer.flags, columns, rows, true);
        let mut workspace = ColumnarCompressionWorkspace::new();
        for column in &buffer.columns {
            ColumnarEncoder::encode_compressed_column_block(&mut output, column, &mut workspace)?;
        }
        ColumnarEncoder::patch_payload_size(&mut output, position, start)?;
        Ok(output)
    }
}

use encoder::{encode_without_scratch_seed, ColumnarEncoder};
use protocol::{
    columnar::{ColumnData, ColumnMetadata, RowBufferV2},
    OdbcType,
};
use std::{hint::black_box, time::Instant};

fn mixed(rows: usize, columns: usize) -> RowBufferV2 {
    let mut buffer = RowBufferV2::new();
    buffer.set_row_count(rows);
    for c in 0..columns {
        let (name, odbc_type, data) = match c % 4 {
            0 => (
                format!("int_{c}"),
                OdbcType::Integer,
                ColumnData::Integer((0..rows).map(|r| Some(r as i32)).collect()),
            ),
            1 => (
                format!("big_{c}"),
                OdbcType::BigInt,
                ColumnData::BigInt((0..rows).map(|r| Some(r as i64 * 1_000_003)).collect()),
            ),
            2 => (
                format!("name_{c}"),
                OdbcType::Varchar,
                ColumnData::Varchar(
                    (0..rows)
                        .map(|r| Some(format!("row_{r}_col_{c}").into_bytes()))
                        .collect(),
                ),
            ),
            _ => (
                format!("bin_{c}"),
                OdbcType::Binary,
                ColumnData::Binary((0..rows).map(|r| Some(vec![r as u8; 32])).collect()),
            ),
        };
        buffer.add_column(ColumnMetadata { name, odbc_type }, data);
    }
    buffer
}

fn numeric(null_every: usize) -> RowBufferV2 {
    let mut buffer = RowBufferV2::new();
    buffer.set_row_count(100_000);
    let present = |i: usize| null_every == 0 || !i.is_multiple_of(null_every);
    buffer.add_column(
        ColumnMetadata {
            name: "id".to_string(),
            odbc_type: OdbcType::Integer,
        },
        ColumnData::Integer(
            (0..100_000)
                .map(|i| present(i).then_some(i as i32))
                .collect(),
        ),
    );
    buffer.add_column(
        ColumnMetadata {
            name: "big".to_string(),
            odbc_type: OdbcType::BigInt,
        },
        ColumnData::BigInt(
            (0..100_000)
                .map(|i| present(i).then_some(i as i64 * 1_000_000_000))
                .collect(),
        ),
    );
    buffer
}

type Encode = fn(&RowBufferV2, bool) -> error::Result<Vec<u8>>;
fn measure(encode: Encode, buffer: &RowBufferV2, compressed: bool, iterations: usize) -> f64 {
    let start = Instant::now();
    for _ in 0..iterations {
        black_box(encode(black_box(buffer), compressed).expect("valid fixture"));
    }
    start.elapsed().as_nanos() as f64 / iterations as f64
}

fn median(values: &[f64]) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    sorted[sorted.len() / 2]
}

fn interval(ratios: &[f64]) -> (f64, f64) {
    let mut state = 20261106u64;
    let mut medians = Vec::with_capacity(10_000);
    for _ in 0..10_000 {
        let sample: Vec<_> = (0..ratios.len())
            .map(|_| {
                state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
                ratios[(state >> 32) as usize % ratios.len()]
            })
            .collect();
        medians.push(median(&sample));
    }
    medians.sort_by(f64::total_cmp);
    (medians[250], medians[9750])
}

fn main() {
    println!("case,before_ns,after_ns,paired_speedup,ci_low,ci_high");
    for (name, buffer, compressed, iterations) in [
        ("compressed_100x8", mixed(100, 8), true, 256),
        ("compressed_1000x8", mixed(1000, 8), true, 32),
        ("dense", numeric(0), false, 32),
        ("partial_null", numeric(5), false, 32),
        ("all_null", numeric(1), false, 64),
        ("mixed_1000x10", mixed(1000, 10), false, 256),
    ] {
        assert_eq!(
            encode_without_scratch_seed(&buffer, compressed).expect("reference bytes"),
            ColumnarEncoder::encode(&buffer, compressed).expect("production bytes")
        );
        let mut before = Vec::new();
        let mut after = Vec::new();
        let mut ratios = Vec::new();
        for sample in 0..121usize {
            let (a, b) = if sample.is_multiple_of(2) {
                let a = measure(encode_without_scratch_seed, &buffer, compressed, iterations);
                let b = measure(ColumnarEncoder::encode, &buffer, compressed, iterations);
                (a, b)
            } else {
                let b = measure(ColumnarEncoder::encode, &buffer, compressed, iterations);
                let a = measure(encode_without_scratch_seed, &buffer, compressed, iterations);
                (a, b)
            };
            if sample >= 20 {
                before.push(a);
                after.push(b);
                ratios.push(a / b);
            }
        }
        let (low, high) = interval(&ratios);
        println!(
            "{name},{:.2},{:.2},{:.5},{low:.5},{high:.5}",
            median(&before),
            median(&after),
            median(&ratios)
        );
    }
}

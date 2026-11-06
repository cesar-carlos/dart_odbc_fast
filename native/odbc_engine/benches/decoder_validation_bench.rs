use criterion::{black_box, criterion_group, criterion_main, Criterion};
use odbc_engine::protocol::BinaryProtocolDecoder;

fn wire(rows: u32, columns: u16, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&0x4F444243u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&columns.to_le_bytes());
    out.extend_from_slice(&rows.to_le_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(payload);
    out
}

fn bench_validation(c: &mut Criterion) {
    let mut invalid = wire(1_000_000, 0, &[]);
    invalid[12..16].copy_from_slice(&1u32.to_le_bytes());
    let empty = wire(0, 0, &[]);
    // One integer column named "x", followed by 1000 NULL cells.
    let mut payload = vec![1, 0, 1, 0, b'x'];
    payload.extend_from_slice(&vec![1; 1000]);
    let rows = wire(1000, 1, &payload);
    for (name, data, valid) in [
        ("invalid_million_rows", invalid, false),
        ("valid_empty", empty, true),
        ("valid_1000_nulls", rows, true),
    ] {
        assert_eq!(BinaryProtocolDecoder::parse(&data).is_ok(), valid);
        c.bench_function(name, |b| {
            b.iter(|| black_box(BinaryProtocolDecoder::parse(black_box(&data))))
        });
    }
}

criterion_group!(benches, bench_validation);
criterion_main!(benches);

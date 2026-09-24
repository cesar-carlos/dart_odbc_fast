//! Measure the removed FFI buffer copy using the production parameter parser.

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion};
use odbc_engine::protocol::{input_params_from_buffer, ParamValue};

fn wire_blob(size: usize, directed: bool) -> Vec<u8> {
    let value = ParamValue::Binary(vec![7; size]).serialize();
    if !directed {
        return value;
    }
    let mut wire = Vec::with_capacity(9 + value.len());
    wire.extend_from_slice(b"DRT1");
    wire.extend_from_slice(&1u32.to_le_bytes());
    wire.push(0);
    wire.extend_from_slice(&value);
    wire
}

fn bench_stream_param_decode(c: &mut Criterion) {
    let mut group = c.benchmark_group("stream_param_decode");
    for (size, directed) in [
        (1024usize, false),
        (1024 * 1024, false),
        (16 * 1024 * 1024, false),
        (1024 * 1024, true),
    ] {
        let wire = wire_blob(size, directed);
        let name = if directed { "drt1" } else { "legacy" };
        group.bench_with_input(
            BenchmarkId::new(format!("copied_{name}"), size),
            &wire,
            |b, wire| {
                b.iter(|| {
                    let copy = black_box(wire).to_vec();
                    black_box(input_params_from_buffer(&copy).expect("parameters"));
                });
            },
        );
        group.bench_with_input(
            BenchmarkId::new(format!("borrowed_{name}"), size),
            &wire,
            |b, wire| {
                b.iter(|| {
                    black_box(input_params_from_buffer(black_box(wire)).expect("parameters"))
                });
            },
        );
    }
    group.finish();
}

criterion_group!(benches, bench_stream_param_decode);
criterion_main!(benches);

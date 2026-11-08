use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use odbc_engine::protocol::{
    bulk_rows_from_vecs, parse_bulk_insert_payload, serialize_bulk_insert_payload,
    serialize_bulk_insert_payload_v2, BulkColumnData, BulkColumnSpec, BulkColumnType,
    BulkInsertPayload,
};

fn benchmark(c: &mut Criterion) {
    let mut group = c.benchmark_group("bulk_parse");
    for (rows, width) in [(8, 16), (1024, 64), (1024, 4096)] {
        let payload = BulkInsertPayload {
            table: "bench".into(),
            columns: vec![BulkColumnSpec {
                name: "bytes".into(),
                col_type: BulkColumnType::Binary,
                nullable: false,
                max_len: width,
            }],
            row_count: rows,
            column_data: vec![BulkColumnData::Binary {
                rows: bulk_rows_from_vecs((0..rows).map(|_| vec![42; width])),
                max_len: width,
                null_bitmap: None,
            }],
        };
        for (name, wire) in [
            (
                "legacy",
                serialize_bulk_insert_payload(&payload).expect("legacy"),
            ),
            (
                "v2",
                serialize_bulk_insert_payload_v2(&payload).expect("v2"),
            ),
        ] {
            assert_eq!(
                parse_bulk_insert_payload(&wire).expect("valid").row_count,
                rows
            );
            group.throughput(Throughput::Bytes(wire.len() as u64));
            group.bench_with_input(
                BenchmarkId::new(name, format!("{rows}x{width}")),
                &wire,
                |b, wire| {
                    b.iter(|| {
                        black_box(parse_bulk_insert_payload(black_box(wire)).expect("parse"))
                    });
                },
            );
        }
    }
    group.finish();
}
criterion_group!(benches, benchmark);
criterion_main!(benches);

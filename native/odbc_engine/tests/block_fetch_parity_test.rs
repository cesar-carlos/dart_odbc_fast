//! Parity regression for sprint 1 + 2 of the engine-perf plan.
//!
//! These tests run regardless of whether `block-cursor-fetch` is enabled —
//! when the feature is off they exercise only the row-major + transpose
//! path; when it's on they additionally validate that the column-major
//! direct fetch produces a buffer that the existing
//! `ColumnarEncoder::encode` serialises identically to the legacy
//! `row_buffer_to_columnar` route.
//!
//! Cursor-bound paths require a real ODBC driver and are covered by the
//! existing CI matrix (cargo test --features block-cursor-fetch). Here we
//! validate the post-fetch invariants: anything the new fetcher would
//! produce must round-trip through the encoders bit-for-bit identically
//! to what the legacy fetcher produced.

use odbc_engine::protocol::{
    columnar::{ColumnData, ColumnMetadata, RowBufferV2},
    row_buffer_to_columnar, ColumnarEncoder, OdbcType, RowBuffer, RowBufferEncoder,
};

fn fixture_row_buffer() -> RowBuffer {
    let mut rb = RowBuffer::new();
    rb.add_column("id".to_string(), OdbcType::Integer);
    rb.add_column("name".to_string(), OdbcType::Varchar);
    rb.add_column("big".to_string(), OdbcType::BigInt);
    rb.add_column("payload".to_string(), OdbcType::Binary);

    rb.add_row_vecs(vec![
        Some(1i32.to_le_bytes().to_vec()),
        Some(b"Alice".to_vec()),
        Some(100i64.to_le_bytes().to_vec()),
        Some(vec![0xAA, 0xBB, 0xCC]),
    ]);
    rb.add_row_vecs(vec![None, Some(b"".to_vec()), None, Some(vec![])]);
    rb.add_row_vecs(vec![
        Some(42i32.to_le_bytes().to_vec()),
        None,
        Some(i64::MAX.to_le_bytes().to_vec()),
        Some(vec![0x01; 7]),
    ]);

    rb
}

/// Equivalent `RowBufferV2` content laid out column-major. This is the
/// shape `columnar_fetch::fetch_columnar_into` would produce from the
/// same data; we build it manually because that helper requires a live
/// `odbc_api::Cursor`.
fn fixture_row_buffer_v2() -> RowBufferV2 {
    let mut v2 = RowBufferV2::with_capacity(4);
    v2.set_row_count(3);
    v2.add_column(
        ColumnMetadata {
            name: "id".to_string(),
            odbc_type: OdbcType::Integer,
        },
        ColumnData::Integer(vec![Some(1), None, Some(42)]),
    );
    v2.add_column(
        ColumnMetadata {
            name: "name".to_string(),
            odbc_type: OdbcType::Varchar,
        },
        ColumnData::Varchar(vec![Some(b"Alice".to_vec()), Some(b"".to_vec()), None]),
    );
    v2.add_column(
        ColumnMetadata {
            name: "big".to_string(),
            odbc_type: OdbcType::BigInt,
        },
        ColumnData::BigInt(vec![Some(100), None, Some(i64::MAX)]),
    );
    v2.add_column(
        ColumnMetadata {
            name: "payload".to_string(),
            odbc_type: OdbcType::Binary,
        },
        ColumnData::Binary(vec![
            Some(vec![0xAA, 0xBB, 0xCC]),
            Some(vec![]),
            Some(vec![0x01; 7]),
        ]),
    );
    v2
}

#[test]
fn direct_v2_matches_row_to_columnar_byte_for_byte_uncompressed() {
    let row_major = fixture_row_buffer();
    let via_transpose = row_buffer_to_columnar(row_major).expect("transpose");
    let direct = fixture_row_buffer_v2();

    let bytes_via_transpose = ColumnarEncoder::encode(&via_transpose, false).expect("encode");
    let bytes_direct = ColumnarEncoder::encode(&direct, false).expect("encode");

    assert_eq!(
        bytes_via_transpose, bytes_direct,
        "direct columnar buffer must encode to identical wire bytes as the row-major + transpose path"
    );
}

#[test]
fn direct_v2_matches_row_to_columnar_byte_for_byte_compressed() {
    let row_major = fixture_row_buffer();
    let via_transpose = row_buffer_to_columnar(row_major).expect("transpose");
    let direct = fixture_row_buffer_v2();

    let bytes_via_transpose = ColumnarEncoder::encode(&via_transpose, true).expect("encode");
    let bytes_direct = ColumnarEncoder::encode(&direct, true).expect("encode");

    assert_eq!(
        bytes_via_transpose, bytes_direct,
        "compressed columnar bytes must match between transpose and direct paths"
    );
}

#[test]
fn row_major_encoder_roundtrip_matches_decoder_for_fixture() {
    let row_major = fixture_row_buffer();
    let bytes = RowBufferEncoder::encode_result(&row_major).expect("encode");
    let decoded = odbc_engine::protocol::BinaryProtocolDecoder::parse(&bytes).expect("decode");
    assert_eq!(decoded.column_count, 4);
    assert_eq!(decoded.row_count, 3);
    assert_eq!(decoded.columns[0].name, "id");
    assert_eq!(decoded.columns[1].name, "name");
    assert_eq!(decoded.columns[2].name, "big");
    assert_eq!(decoded.columns[3].name, "payload");
}

#[test]
fn empty_buffer_parity_uncompressed() {
    let rb = RowBuffer::new();
    let via_transpose = row_buffer_to_columnar(rb).expect("transpose");
    let direct = RowBufferV2::with_capacity(0);

    let bytes_via_transpose = ColumnarEncoder::encode(&via_transpose, false).expect("encode");
    let bytes_direct = ColumnarEncoder::encode(&direct, false).expect("encode");

    assert_eq!(bytes_via_transpose, bytes_direct);
}

#[test]
fn integer_only_parity() {
    let mut rb = RowBuffer::new();
    rb.add_column("n".to_string(), OdbcType::Integer);
    for i in 0i32..50 {
        rb.add_row_vecs(vec![Some(i.to_le_bytes().to_vec())]);
    }
    let via_transpose = row_buffer_to_columnar(rb).expect("transpose");

    let mut direct = RowBufferV2::with_capacity(1);
    direct.set_row_count(50);
    direct.add_column(
        ColumnMetadata {
            name: "n".to_string(),
            odbc_type: OdbcType::Integer,
        },
        ColumnData::Integer((0i32..50).map(Some).collect()),
    );

    assert_eq!(
        ColumnarEncoder::encode(&via_transpose, false).expect("encode"),
        ColumnarEncoder::encode(&direct, false).expect("encode")
    );
}

#[test]
fn varchar_with_nulls_parity() {
    let mut rb = RowBuffer::new();
    rb.add_column("name".to_string(), OdbcType::Varchar);
    rb.add_row_vecs(vec![Some(b"alpha".to_vec())]);
    rb.add_row_vecs(vec![None]);
    rb.add_row_vecs(vec![Some(b"".to_vec())]);
    rb.add_row_vecs(vec![Some("café".as_bytes().to_vec())]);

    let via_transpose = row_buffer_to_columnar(rb).expect("transpose");

    let mut direct = RowBufferV2::with_capacity(1);
    direct.set_row_count(4);
    direct.add_column(
        ColumnMetadata {
            name: "name".to_string(),
            odbc_type: OdbcType::Varchar,
        },
        ColumnData::Varchar(vec![
            Some(b"alpha".to_vec()),
            None,
            Some(b"".to_vec()),
            Some("café".as_bytes().to_vec()),
        ]),
    );

    assert_eq!(
        ColumnarEncoder::encode(&via_transpose, false).expect("encode"),
        ColumnarEncoder::encode(&direct, false).expect("encode")
    );
}

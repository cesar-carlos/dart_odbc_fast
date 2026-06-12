use super::{
    bulk_rows_from_vecs, parse_bulk_insert_payload, serialize_bulk_insert_payload,
    trim_legacy_nul_padded_cell, BulkColumnData, BulkColumnSpec, BulkColumnType, BulkInsertPayload,
    BulkTimestamp, BULK_V2_MAGIC, TAG_I32, TAG_I64,
};

#[test]
fn legacy_parse_trims_nul_padding_before_copying_cell() {
    assert_eq!(trim_legacy_nul_padded_cell(b"abc\0\0"), b"abc");
    assert_eq!(trim_legacy_nul_padded_cell(b"abc"), b"abc");
    assert_eq!(trim_legacy_nul_padded_cell(b"\0abc"), b"");
}
#[test]
fn should_roundtrip_i64_when_legacy_wire() {
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "n".to_string(),
            col_type: BulkColumnType::I64,
            nullable: false,
            max_len: 0,
        }],
        row_count: 2,
        column_data: vec![BulkColumnData::I64 {
            values: vec![i64::MIN, i64::MAX],
            null_bitmap: None,
        }],
    };
    let enc = serialize_bulk_insert_payload(&payload).expect("serialize");
    let dec = parse_bulk_insert_payload(&enc).expect("parse");
    match &dec.column_data[0] {
        BulkColumnData::I64 { values, .. } => {
            assert_eq!(values.as_slice(), &[i64::MIN, i64::MAX]);
        }
        _ => panic!("expected I64"),
    }
}
#[test]
fn should_roundtrip_decimal_when_legacy_wire() {
    let payload = BulkInsertPayload {
        table: "amounts".to_string(),
        columns: vec![BulkColumnSpec {
            name: "val".to_string(),
            col_type: BulkColumnType::Decimal,
            nullable: false,
            max_len: 8,
        }],
        row_count: 2,
        column_data: vec![BulkColumnData::Text {
            rows: bulk_rows_from_vecs(vec![b"3.14\0\0\0\0".to_vec(), b"-1.5\0\0\0".to_vec()]),
            max_len: 8,
            null_bitmap: None,
        }],
    };
    let enc = serialize_bulk_insert_payload(&payload).expect("serialize legacy");
    let dec = parse_bulk_insert_payload(&enc).expect("parse legacy");
    match &dec.column_data[0] {
        BulkColumnData::Text { rows, max_len, .. } => {
            assert_eq!(*max_len, 8);
            assert_eq!(rows[0], b"3.14");
            assert_eq!(rows[1], b"-1.5");
        }
        _ => panic!("expected Text-backed Decimal"),
    }
}
#[test]
fn should_roundtrip_legacy_timestamp_without_v2_magic() {
    let ts = BulkTimestamp {
        year: 1999,
        month: 12,
        day: 31,
        hour: 23,
        minute: 59,
        second: 59,
        fraction: 0,
    };
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "ts".to_string(),
            col_type: BulkColumnType::Timestamp,
            nullable: false,
            max_len: 0,
        }],
        row_count: 1,
        column_data: vec![BulkColumnData::Timestamp {
            values: vec![ts],
            null_bitmap: None,
        }],
    };
    let enc = serialize_bulk_insert_payload(&payload).expect("legacy serialize");
    assert!(!enc.starts_with(BULK_V2_MAGIC));
    let dec = parse_bulk_insert_payload(&enc).expect("legacy parse");
    match &dec.column_data[0] {
        BulkColumnData::Timestamp { values, .. } => assert_eq!(values[0], ts),
        _ => panic!("expected Timestamp"),
    }
}
#[test]
fn should_reject_invalid_utf8_table_name_when_legacy() {
    let mut v = Vec::new();
    v.extend_from_slice(&3u32.to_le_bytes());
    v.extend_from_slice(&[0xFF, 0xFE, 0x80]);
    v.extend_from_slice(&0u32.to_le_bytes());
    let err = parse_bulk_insert_payload(&v).expect_err("utf8 table");
    assert!(err.to_string().contains("invalid UTF-8"));
}
#[test]
fn should_reject_invalid_utf8_column_name_when_legacy() {
    let mut v = Vec::new();
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"t");
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(&2u32.to_le_bytes());
    v.extend_from_slice(&[0xC0, 0x80]);
    let err = parse_bulk_insert_payload(&v).expect_err("utf8 column");
    assert!(err.to_string().contains("invalid UTF-8"));
}
#[test]
fn parse_legacy_rejects_truncated_i64_column() {
    let mut v = Vec::new();
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"t");
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"n");
    v.push(TAG_I64);
    v.push(0);
    v.extend_from_slice(&0u32.to_le_bytes());
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
    let err = parse_bulk_insert_payload(&v).expect_err("truncated i64");
    assert!(err.to_string().contains("truncated (i64)"));
}
#[test]
fn should_roundtrip_legacy_binary_nullable_with_bitmap() {
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "b".to_string(),
            col_type: BulkColumnType::Binary,
            nullable: true,
            max_len: 4,
        }],
        row_count: 2,
        column_data: vec![BulkColumnData::Binary {
            rows: bulk_rows_from_vecs(vec![vec![1, 2], vec![]]),
            max_len: 4,
            null_bitmap: Some(vec![0b10]),
        }],
    };
    let enc = serialize_bulk_insert_payload(&payload).expect("serialize");
    let dec = parse_bulk_insert_payload(&enc).expect("parse");
    match &dec.column_data[0] {
        BulkColumnData::Binary {
            rows, null_bitmap, ..
        } => {
            assert_eq!(rows[0], vec![1, 2]);
            assert_eq!(rows[1], Vec::<u8>::new());
            assert_eq!(null_bitmap.as_deref(), Some(&[0b10][..]));
        }
        _ => panic!("expected Binary"),
    }
}
#[test]
fn should_reject_legacy_when_column_spec_truncated() {
    let mut v = Vec::new();
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"t");
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"c");
    v.push(TAG_I32);
    let err = parse_bulk_insert_payload(&v).expect_err("truncated spec");
    assert!(err.to_string().contains("truncated"));
}
#[test]
fn parse_legacy_rejects_truncated_u32_at_table_length() {
    let err = parse_bulk_insert_payload(&[0u8]).expect_err("truncated u32");
    assert!(err.to_string().contains("truncated (u32)"));
}
#[test]
fn parse_legacy_rejects_truncated_bytes_when_reading_table_name() {
    let mut v = Vec::new();
    v.extend_from_slice(&4u32.to_le_bytes());
    v.extend_from_slice(&[1, 2]);
    let err = parse_bulk_insert_payload(&v).expect_err("truncated bytes");
    assert!(err.to_string().contains("truncated (bytes)"));
}
#[test]
fn parse_legacy_rejects_truncated_nullable_flag_in_column_spec() {
    let mut v = Vec::new();
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"t");
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"a");
    v.push(TAG_I32);
    let err = parse_bulk_insert_payload(&v).expect_err("nullable truncated");
    assert!(err.to_string().contains("truncated"));
}

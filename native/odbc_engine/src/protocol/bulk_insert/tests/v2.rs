use super::{
    bulk_rows_from_vecs, parse_bulk_insert_payload, serialize_bulk_insert_payload_v2,
    BulkColumnData, BulkColumnSpec, BulkColumnType, BulkInsertPayload, BulkTimestamp,
    BULK_V2_VERSION, MAX_BULK_CELL_LEN, TAG_BINARY,
};

#[test]
fn parse_v2_preserves_binary_nul_bytes() {
    let payload = BulkInsertPayload {
        table: "files".to_string(),
        columns: vec![BulkColumnSpec {
            name: "payload".to_string(),
            col_type: BulkColumnType::Binary,
            nullable: false,
            max_len: 8,
        }],
        row_count: 1,
        column_data: vec![BulkColumnData::Binary {
            rows: bulk_rows_from_vecs(vec![vec![1, 0, 2, 0, 3]]),
            max_len: 8,
            null_bitmap: None,
        }],
    };

    let enc = serialize_bulk_insert_payload_v2(&payload).expect("serialize v2");
    assert_eq!(&enc[..4], b"BLK2");
    let dec = parse_bulk_insert_payload(&enc).expect("parse v2");

    match &dec.column_data[0] {
        BulkColumnData::Binary { rows, max_len, .. } => {
            assert_eq!(*max_len, 8);
            assert_eq!(rows[0], vec![1, 0, 2, 0, 3]);
        }
        _ => panic!("expected Binary"),
    }
}
#[test]
fn parse_v2_accepts_variable_binary_when_max_len_zero() {
    let payload = BulkInsertPayload {
        table: "files".to_string(),
        columns: vec![BulkColumnSpec {
            name: "payload".to_string(),
            col_type: BulkColumnType::Binary,
            nullable: false,
            max_len: 0,
        }],
        row_count: 1,
        column_data: vec![BulkColumnData::Binary {
            rows: bulk_rows_from_vecs(vec![vec![9, 8, 0, 7, 6]]),
            max_len: 0,
            null_bitmap: None,
        }],
    };

    let enc = serialize_bulk_insert_payload_v2(&payload).expect("serialize v2");
    let dec = parse_bulk_insert_payload(&enc).expect("parse v2");

    match &dec.column_data[0] {
        BulkColumnData::Binary { rows, max_len, .. } => {
            assert_eq!(*max_len, 0);
            assert_eq!(rows[0], vec![9, 8, 0, 7, 6]);
        }
        _ => panic!("expected Binary"),
    }
}
#[test]
fn parse_v2_rejects_cell_over_column_max_len() {
    let mut enc = Vec::new();
    enc.extend_from_slice(b"BLK2");
    enc.extend_from_slice(&2u16.to_le_bytes());
    enc.extend_from_slice(&0u16.to_le_bytes());
    enc.extend_from_slice(&1u32.to_le_bytes());
    enc.extend_from_slice(b"t");
    enc.extend_from_slice(&1u32.to_le_bytes());
    enc.extend_from_slice(&1u32.to_le_bytes());
    enc.extend_from_slice(b"b");
    enc.push(TAG_BINARY);
    enc.push(0);
    enc.extend_from_slice(&2u32.to_le_bytes());
    enc.extend_from_slice(&1u32.to_le_bytes());
    enc.extend_from_slice(&3u32.to_le_bytes());
    enc.extend_from_slice(&[1, 2, 3]);

    let e = parse_bulk_insert_payload(&enc).expect_err("max len");
    assert!(e.to_string().contains("exceeds column max_len"));
}
#[test]
fn parse_v2_rejects_truncated_variable_cell() {
    let mut enc = Vec::new();
    enc.extend_from_slice(b"BLK2");
    enc.extend_from_slice(&2u16.to_le_bytes());
    enc.extend_from_slice(&0u16.to_le_bytes());
    enc.extend_from_slice(&1u32.to_le_bytes());
    enc.extend_from_slice(b"t");
    enc.extend_from_slice(&1u32.to_le_bytes());
    enc.extend_from_slice(&1u32.to_le_bytes());
    enc.extend_from_slice(b"b");
    enc.push(TAG_BINARY);
    enc.push(0);
    enc.extend_from_slice(&8u32.to_le_bytes());
    enc.extend_from_slice(&1u32.to_le_bytes());
    enc.extend_from_slice(&4u32.to_le_bytes());
    enc.extend_from_slice(&[1, 2]);

    let e = parse_bulk_insert_payload(&enc).expect_err("truncated");
    assert!(e.to_string().contains("truncated"));
}
#[test]
fn should_roundtrip_timestamp_when_v2_wire() {
    let ts = BulkTimestamp {
        year: 2024,
        month: 6,
        day: 15,
        hour: 10,
        minute: 30,
        second: 45,
        fraction: 123_456,
    };
    let payload = BulkInsertPayload {
        table: "events".to_string(),
        columns: vec![BulkColumnSpec {
            name: "at".to_string(),
            col_type: BulkColumnType::Timestamp,
            nullable: true,
            max_len: 0,
        }],
        row_count: 1,
        column_data: vec![BulkColumnData::Timestamp {
            values: vec![ts],
            null_bitmap: Some(vec![0]),
        }],
    };
    let enc = serialize_bulk_insert_payload_v2(&payload).expect("serialize v2");
    let dec = parse_bulk_insert_payload(&enc).expect("parse v2");
    match &dec.column_data[0] {
        BulkColumnData::Timestamp { values, .. } => assert_eq!(values[0], ts),
        _ => panic!("expected Timestamp"),
    }
}
#[test]
fn should_reject_v2_when_version_not_two() {
    let mut enc = Vec::new();
    enc.extend_from_slice(b"BLK2");
    enc.extend_from_slice(&1u16.to_le_bytes());
    enc.extend_from_slice(&0u16.to_le_bytes());
    let err = parse_bulk_insert_payload(&enc).expect_err("bad version");
    assert!(err
        .to_string()
        .contains("Unsupported bulk insert payload version"));
}
#[test]
fn should_reject_v2_when_flags_nonzero() {
    let mut enc = Vec::new();
    enc.extend_from_slice(b"BLK2");
    enc.extend_from_slice(&BULK_V2_VERSION.to_le_bytes());
    enc.extend_from_slice(&1u16.to_le_bytes());
    let err = parse_bulk_insert_payload(&enc).expect_err("bad flags");
    assert!(err
        .to_string()
        .contains("Unsupported bulk insert payload flags"));
}
#[test]
fn should_roundtrip_decimal_unicode_when_v2_wire() {
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "note".to_string(),
            col_type: BulkColumnType::Decimal,
            nullable: false,
            max_len: 0,
        }],
        row_count: 1,
        column_data: vec![BulkColumnData::Text {
            rows: bulk_rows_from_vecs(vec!["café".as_bytes().to_vec()]),
            max_len: 0,
            null_bitmap: None,
        }],
    };
    let enc = serialize_bulk_insert_payload_v2(&payload).expect("serialize v2");
    let dec = parse_bulk_insert_payload(&enc).expect("parse v2");
    match &dec.column_data[0] {
        BulkColumnData::Text { rows, .. } => assert_eq!(rows[0], "café".as_bytes()),
        _ => panic!("expected Text"),
    }
}
#[test]
fn serialize_v2_rejects_variable_row_count_mismatch() {
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "b".to_string(),
            col_type: BulkColumnType::Binary,
            nullable: false,
            max_len: 0,
        }],
        row_count: 2,
        column_data: vec![BulkColumnData::Binary {
            rows: bulk_rows_from_vecs(vec![vec![1]]),
            max_len: 0,
            null_bitmap: None,
        }],
    };
    let err = serialize_bulk_insert_payload_v2(&payload).expect_err("row mismatch");
    assert!(err.to_string().contains("row count mismatch"));
}
#[test]
fn parse_v2_rejects_cell_over_global_max_bulk_cell_len() {
    let mut enc = Vec::new();
    enc.extend_from_slice(b"BLK2");
    enc.extend_from_slice(&BULK_V2_VERSION.to_le_bytes());
    enc.extend_from_slice(&0u16.to_le_bytes());
    enc.extend_from_slice(&1u32.to_le_bytes());
    enc.extend_from_slice(b"t");
    enc.extend_from_slice(&1u32.to_le_bytes());
    enc.extend_from_slice(&1u32.to_le_bytes());
    enc.extend_from_slice(b"b");
    enc.push(TAG_BINARY);
    enc.push(0);
    enc.extend_from_slice(&0u32.to_le_bytes());
    enc.extend_from_slice(&1u32.to_le_bytes());
    enc.extend_from_slice(&(MAX_BULK_CELL_LEN as u32 + 1).to_le_bytes());
    let err = parse_bulk_insert_payload(&enc).expect_err("global cell max");
    assert!(err.to_string().contains("MAX_BULK_CELL_LEN"));
}
#[test]
fn should_reject_v2_when_magic_header_truncated() {
    let err = parse_bulk_insert_payload(b"BLK").expect_err("short header");
    assert!(err.to_string().contains("truncated"));
}
#[test]
fn parse_v2_rejects_truncated_u16_after_magic() {
    let err = parse_bulk_insert_payload(b"BLK2").expect_err("truncated u16");
    assert!(err.to_string().contains("truncated (u16)"));
}

use super::{
    parse_bulk_insert_payload, serialize_bulk_insert_payload, BulkColumnData, BulkColumnSpec,
    BulkColumnType, BulkInsertPayload, BULK_V2_VERSION, MAX_BULK_CELL_LEN, MAX_BULK_COLUMNS,
    MAX_BULK_ROWS, TAG_BINARY, TAG_I32, TAG_TEXT,
};

#[test]
fn serialize_rejects_too_many_rows() {
    let p = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "a".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: (MAX_BULK_ROWS as u32).saturating_add(1),
        column_data: vec![BulkColumnData::I32 {
            values: vec![],
            null_bitmap: None,
        }],
    };
    let e = serialize_bulk_insert_payload(&p).expect_err("rows");
    assert!(e.to_string().contains("MAX_BULK_ROWS"));
}
#[test]
fn serialize_rejects_max_len_too_large() {
    let p = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "a".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: MAX_BULK_CELL_LEN + 1,
        }],
        row_count: 0,
        column_data: vec![BulkColumnData::I32 {
            values: vec![],
            null_bitmap: None,
        }],
    };
    let e = serialize_bulk_insert_payload(&p).expect_err("max_len");
    assert!(e.to_string().contains("MAX_BULK_CELL_LEN"));
}
#[test]
fn parse_rejects_unknown_column_type_tag() {
    let mut v = Vec::new();
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"t");
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"a");
    v.push(0xFFu8);
    v.push(0u8);
    v.extend_from_slice(&0u32.to_le_bytes());
    v.extend_from_slice(&0u32.to_le_bytes());
    let e = parse_bulk_insert_payload(&v).expect_err("type tag");
    assert!(e.to_string().contains("Unknown bulk column type tag"));
}
#[test]
fn parse_rejects_trailing_garbage() {
    let p = serialize_bulk_insert_payload(&BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "a".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: 0,
        column_data: vec![BulkColumnData::I32 {
            values: vec![],
            null_bitmap: None,
        }],
    })
    .expect("ok");
    let mut w = p;
    w.push(0);
    let e = parse_bulk_insert_payload(&w).expect_err("mismatch");
    assert!(e.to_string().contains("length mismatch"));
}
#[test]
fn should_reject_parse_when_column_count_exceeds_max() {
    let mut v = Vec::new();
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"t");
    v.extend_from_slice(&((MAX_BULK_COLUMNS as u32) + 1).to_le_bytes());
    let err = parse_bulk_insert_payload(&v).expect_err("columns");
    assert!(err.to_string().contains("MAX_BULK_COLUMNS"));
}
#[test]
fn should_reject_variable_cell_when_exceeds_max_bulk_cell_len() {
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
    let err = parse_bulk_insert_payload(&enc).expect_err("cell len");
    assert!(err.to_string().contains("MAX_BULK_CELL_LEN"));
}
#[test]
fn should_error_when_serialize_column_data_mismatch() {
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "a".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: 1,
        column_data: vec![BulkColumnData::Text {
            rows: vec![b"x".to_vec()],
            max_len: 4,
            null_bitmap: None,
        }],
    };
    let err = serialize_bulk_insert_payload(&payload).expect_err("mismatch");
    assert!(err.to_string().contains("does not match spec"));
}
#[test]
fn should_reject_parse_when_row_count_exceeds_max() {
    let mut v = Vec::new();
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"t");
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"a");
    v.push(TAG_I32);
    v.push(0);
    v.extend_from_slice(&0u32.to_le_bytes());
    v.extend_from_slice(&((MAX_BULK_ROWS as u32) + 1).to_le_bytes());
    let err = parse_bulk_insert_payload(&v).expect_err("rows");
    assert!(err.to_string().contains("MAX_BULK_ROWS"));
}
#[test]
fn parse_rejects_column_max_len_over_bulk_cell_cap() {
    let mut v = Vec::new();
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"t");
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(&1u32.to_le_bytes());
    v.extend_from_slice(b"c");
    v.push(TAG_TEXT);
    v.push(0);
    v.extend_from_slice(&((MAX_BULK_CELL_LEN as u32) + 1).to_le_bytes());
    v.extend_from_slice(&0u32.to_le_bytes());
    let err = parse_bulk_insert_payload(&v).expect_err("max_len");
    assert!(err.to_string().contains("MAX_BULK_CELL_LEN"));
}
#[test]
fn serialize_rejects_column_count_over_max() {
    let p = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![
            BulkColumnSpec {
                name: "a".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            };
            MAX_BULK_COLUMNS + 1
        ],
        row_count: 0,
        column_data: vec![
            BulkColumnData::I32 {
                values: vec![],
                null_bitmap: None,
            };
            MAX_BULK_COLUMNS + 1
        ],
    };
    let err = serialize_bulk_insert_payload(&p).expect_err("columns");
    assert!(err.to_string().contains("MAX_BULK_COLUMNS"));
}

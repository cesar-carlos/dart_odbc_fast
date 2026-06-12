use super::{
    bulk_rows_from_vecs, parse_bulk_insert_payload, serialize_bulk_insert_payload, BulkColumnData,
    BulkColumnSpec, BulkColumnType, BulkInsertPayload,
};

#[test]
fn test_bulk_insert_parse_roundtrip_i32() {
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "a".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: 2,
        column_data: vec![BulkColumnData::I32 {
            values: vec![1, 2],
            null_bitmap: None,
        }],
    };
    let enc = serialize_bulk_insert_payload(&payload).unwrap();
    let dec = parse_bulk_insert_payload(&enc).unwrap();
    assert_eq!(dec.table, "t");
    assert_eq!(dec.columns.len(), 1);
    assert_eq!(dec.columns[0].name, "a");
    assert!(!dec.columns[0].nullable);
    assert_eq!(dec.row_count, 2);
    match &dec.column_data[0] {
        BulkColumnData::I32 {
            values,
            null_bitmap,
        } => {
            assert_eq!(values.as_slice(), &[1, 2]);
            assert!(null_bitmap.is_none());
        }
        _ => panic!("expected I32"),
    }
}
#[test]
fn test_bulk_insert_parse_roundtrip_i32_nullable() {
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "a".to_string(),
            col_type: BulkColumnType::I32,
            nullable: true,
            max_len: 0,
        }],
        row_count: 3,
        column_data: vec![BulkColumnData::I32 {
            values: vec![1, 0, 3],
            null_bitmap: Some(vec![0b010]),
        }],
    };
    let enc = serialize_bulk_insert_payload(&payload).unwrap();
    let dec = parse_bulk_insert_payload(&enc).unwrap();
    assert_eq!(dec.row_count, 3);
    match &dec.column_data[0] {
        BulkColumnData::I32 {
            values,
            null_bitmap,
        } => {
            assert_eq!(values.as_slice(), &[1, 0, 3]);
            assert_eq!(null_bitmap.as_deref(), Some(&[0b010][..]));
        }
        _ => panic!("expected I32"),
    }
}
#[test]
fn test_bulk_insert_parse_roundtrip_text() {
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "x".to_string(),
            col_type: BulkColumnType::Text,
            nullable: false,
            max_len: 10,
        }],
        row_count: 2,
        column_data: vec![BulkColumnData::Text {
            rows: bulk_rows_from_vecs(vec![b"hi".to_vec(), b"world".to_vec()]),
            max_len: 10,
            null_bitmap: None,
        }],
    };
    let enc = serialize_bulk_insert_payload(&payload).unwrap();
    let dec = parse_bulk_insert_payload(&enc).unwrap();
    assert_eq!(dec.table, "t");
    match &dec.column_data[0] {
        BulkColumnData::Text { rows, max_len, .. } => {
            assert_eq!(*max_len, 10);
            assert_eq!(rows[0], b"hi");
            assert_eq!(rows[1], b"world");
        }
        _ => panic!("expected Text"),
    }
}

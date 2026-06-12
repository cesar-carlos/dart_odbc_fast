use super::{
    bulk_rows_from_vecs, estimate_serialized_payload_size, serialize_bulk_insert_payload,
    serialize_bulk_insert_payload_v2, BulkColumnData, BulkColumnSpec, BulkColumnType,
    BulkInsertPayload, BulkPayloadWire,
};

#[test]
fn estimate_serialized_payload_size_matches_v2_length() {
    let payload = BulkInsertPayload {
        table: "files".to_string(),
        columns: vec![BulkColumnSpec {
            name: "payload".to_string(),
            col_type: BulkColumnType::Binary,
            nullable: false,
            max_len: 0,
        }],
        row_count: 2,
        column_data: vec![BulkColumnData::Binary {
            rows: bulk_rows_from_vecs(vec![vec![1, 0, 2], vec![3, 4]]),
            max_len: 0,
            null_bitmap: None,
        }],
    };

    let estimated =
        estimate_serialized_payload_size(&payload, BulkPayloadWire::V2).expect("estimate");
    let encoded = serialize_bulk_insert_payload_v2(&payload).expect("serialize");

    assert_eq!(estimated, encoded.len());
}
#[test]
fn estimate_legacy_payload_size_matches_encoded_length() {
    let payload = BulkInsertPayload {
        table: "t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "x".to_string(),
            col_type: BulkColumnType::Text,
            nullable: false,
            max_len: 4,
        }],
        row_count: 1,
        column_data: vec![BulkColumnData::Text {
            rows: bulk_rows_from_vecs(vec![b"ab".to_vec()]),
            max_len: 4,
            null_bitmap: None,
        }],
    };
    let estimated =
        estimate_serialized_payload_size(&payload, BulkPayloadWire::Legacy).expect("estimate");
    let encoded = serialize_bulk_insert_payload(&payload).expect("serialize");
    assert_eq!(estimated, encoded.len());
}

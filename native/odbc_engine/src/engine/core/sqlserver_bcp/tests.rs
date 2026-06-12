use super::bound_column::{BoundColumnRef, SQL_NULL_DATA};
use super::helpers::to_wide_nul;
use super::library::trim_symbol_name;
use super::payload::build_bound_columns;
use super::{execute_native_bcp, probe_native_bcp_support};
use crate::error::OdbcError;
use crate::protocol::{BulkColumnData, BulkColumnSpec, BulkColumnType, BulkInsertPayload};

#[test]
fn test_trim_symbol_name() {
    assert_eq!(trim_symbol_name(b"bcp_initW\0"), "bcp_initW");
    assert_eq!(trim_symbol_name(b"bcp_bind"), "bcp_bind");
}

#[test]
fn test_to_wide_nul_appends_terminator() {
    let wide = to_wide_nul("abc");
    assert_eq!(wide, [97, 98, 99, 0]);
    assert_eq!(wide.last(), Some(&0));
}

#[test]
fn test_to_wide_nul_empty_string() {
    assert_eq!(to_wide_nul(""), [0]);
}

#[test]
fn test_build_bound_columns_accepts_nullable_numeric() {
    let payload = BulkInsertPayload {
        table: "dbo.t".to_string(),
        columns: vec![
            BulkColumnSpec {
                name: "id".to_string(),
                col_type: BulkColumnType::I32,
                nullable: true,
                max_len: 0,
            },
            BulkColumnSpec {
                name: "score".to_string(),
                col_type: BulkColumnType::I64,
                nullable: true,
                max_len: 0,
            },
        ],
        row_count: 3,
        column_data: vec![
            BulkColumnData::I32 {
                values: vec![1, 0, 3],
                null_bitmap: Some(vec![0b010]),
            },
            BulkColumnData::I64 {
                values: vec![10, 0, 30],
                null_bitmap: Some(vec![0b010]),
            },
        ],
    };

    let cols = build_bound_columns(&payload).expect("columns should be accepted");
    assert_eq!(cols.len(), 2);
    assert_eq!(cols[0].len(), 3);
    assert_eq!(cols[1].len(), 3);
}

#[test]
fn test_build_bound_columns_rejects_invalid_null_bitmap_size() {
    let payload = BulkInsertPayload {
        table: "dbo.t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "id".to_string(),
            col_type: BulkColumnType::I64,
            nullable: true,
            max_len: 0,
        }],
        row_count: 9,
        column_data: vec![BulkColumnData::I64 {
            values: vec![0; 9],
            null_bitmap: Some(vec![0b0000_0001]),
        }],
    };

    let message = match build_bound_columns(&payload) {
        Ok(_) => panic!("bitmap size should be validated"),
        Err(err) => err.to_string(),
    };
    assert!(message.contains("null bitmap size mismatch"));
}

#[test]
fn test_build_bound_columns_rejects_column_data_length_mismatch() {
    let payload = BulkInsertPayload {
        table: "dbo.t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "id".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: 1,
        column_data: vec![],
    };
    let err = match build_bound_columns(&payload) {
        Err(err) => err,
        Ok(_) => panic!("column/data length mismatch should fail"),
    };
    assert!(matches!(err, OdbcError::ValidationError(_)));
    assert!(err.to_string().contains("payload mismatch"));
}

#[test]
fn test_build_bound_columns_rejects_unsupported_column_type() {
    let payload = BulkInsertPayload {
        table: "dbo.t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "label".to_string(),
            col_type: BulkColumnType::Text,
            nullable: false,
            max_len: 32,
        }],
        row_count: 1,
        column_data: vec![BulkColumnData::Text {
            rows: vec![b"hi".to_vec()],
            null_bitmap: None,
            max_len: 32,
        }],
    };
    let err = match build_bound_columns(&payload) {
        Err(err) => err,
        Ok(_) => panic!("unsupported column type should fail"),
    };
    assert!(matches!(err, OdbcError::UnsupportedFeature(_)));
    assert!(err.to_string().contains("I32/I64"));
}

#[test]
fn test_build_bound_columns_rejects_type_spec_data_mismatch() {
    let payload = BulkInsertPayload {
        table: "dbo.t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "id".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: 1,
        column_data: vec![BulkColumnData::I64 {
            values: vec![1],
            null_bitmap: None,
        }],
    };
    let err = match build_bound_columns(&payload) {
        Err(err) => err,
        Ok(_) => panic!("spec/data type mismatch should fail"),
    };
    assert!(matches!(err, OdbcError::UnsupportedFeature(_)));
    assert!(err.to_string().contains("matching payload type"));
}

#[test]
fn bound_column_i32_row_collen_and_write_row() {
    let values = [10i32, 20, 30];
    let null_bitmap = [0b010u8];
    let mut col = BoundColumnRef::I32 {
        values: &values,
        null_bitmap: Some(&null_bitmap),
        cell: std::mem::MaybeUninit::uninit(),
    };
    col.write_row(1);
    assert_eq!(col.row_collen_for_bcp(1), SQL_NULL_DATA);
    assert_eq!(col.row_collen_for_bcp(0), std::mem::size_of::<i32>() as i32);
    let (ptr, cb_data, sql_type) = col.bind_args_mut();
    assert!(!ptr.is_null());
    assert_eq!(cb_data, std::mem::size_of::<i32>() as i32);
    assert_eq!(sql_type, 56);
}

#[test]
fn bound_column_i64_row_collen_null_without_bitmap() {
    let values = [100i64];
    let mut col = BoundColumnRef::I64 {
        values: &values,
        null_bitmap: None,
        cell: std::mem::MaybeUninit::uninit(),
    };
    col.write_row(0);
    assert_eq!(col.row_collen_for_bcp(0), std::mem::size_of::<i64>() as i32);
}

#[test]
fn execute_native_bcp_empty_payload_returns_zero_without_connect() {
    let payload = BulkInsertPayload {
        table: "dbo.t".to_string(),
        columns: vec![],
        row_count: 0,
        column_data: vec![],
    };
    assert_eq!(
        execute_native_bcp("unused", &payload, 1000).expect("empty insert"),
        0
    );
}

#[test]
fn execute_native_bcp_rejects_row_count_mismatch_before_connect() {
    let payload = BulkInsertPayload {
        table: "dbo.t".to_string(),
        columns: vec![BulkColumnSpec {
            name: "id".to_string(),
            col_type: BulkColumnType::I32,
            nullable: false,
            max_len: 0,
        }],
        row_count: 5,
        column_data: vec![BulkColumnData::I32 {
            values: vec![1, 2, 3],
            null_bitmap: None,
        }],
    };
    let err = match execute_native_bcp("unused", &payload, 1000) {
        Err(err) => err,
        Ok(_) => panic!("row count mismatch should fail before connect"),
    };
    assert!(matches!(err, OdbcError::ValidationError(_)));
    assert!(err.to_string().contains("expected 5"));
}

#[test]
fn probe_native_bcp_support_reports_load_or_symbol_outcome() {
    match probe_native_bcp_support() {
        Ok(()) => {}
        Err(OdbcError::UnsupportedFeature(msg)) => {
            assert!(
                msg.contains("BCP") || msg.contains("library") || msg.contains("symbol"),
                "unexpected message: {msg}"
            );
        }
        other => panic!("unexpected probe result: {other:?}"),
    }
}

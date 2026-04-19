//! C10 — Integer columns must be transported as fixed-width LE bytes;
//! decoders must reject malformed widths instead of silently producing NULL.

use odbc_engine::protocol::{row_buffer_to_columnar, ColumnData, OdbcType, RowBuffer};

#[test]
fn columnar_round_trip_preserves_i32_values() {
    let mut rb = RowBuffer::new();
    rb.add_column("id".to_string(), OdbcType::Integer);
    rb.add_row(vec![Some(42i32.to_le_bytes().to_vec())]);
    rb.add_row(vec![Some((-1i32).to_le_bytes().to_vec())]);
    rb.add_row(vec![None]);

    let v2 = row_buffer_to_columnar(&rb);
    assert_eq!(v2.row_count, 3);
    match &v2.columns[0].data {
        ColumnData::Integer(values) => {
            assert_eq!(values[0], Some(42));
            assert_eq!(values[1], Some(-1));
            assert_eq!(values[2], None);
        }
        _ => panic!("expected Integer column data"),
    }
}

#[test]
fn columnar_preserves_i64_values() {
    let mut rb = RowBuffer::new();
    rb.add_column("id".to_string(), OdbcType::BigInt);
    rb.add_row(vec![Some(i64::MAX.to_le_bytes().to_vec())]);
    rb.add_row(vec![Some(i64::MIN.to_le_bytes().to_vec())]);

    let v2 = row_buffer_to_columnar(&rb);
    match &v2.columns[0].data {
        ColumnData::BigInt(values) => {
            assert_eq!(values[0], Some(i64::MAX));
            assert_eq!(values[1], Some(i64::MIN));
        }
        _ => panic!("expected BigInt column data"),
    }
}

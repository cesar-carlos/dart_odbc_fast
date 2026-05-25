use crate::error::{OdbcError, Result};
use crate::protocol::columnar::{ColumnData, ColumnMetadata, RowBufferV2};
use crate::protocol::row_buffer::RowBuffer;
use crate::protocol::types::OdbcType;

fn decode_integer_cell(
    col_name: &str,
    row_idx: usize,
    cell: Option<&Vec<u8>>,
) -> Result<Option<i32>> {
    match cell {
        None => Ok(None),
        Some(bytes) if bytes.len() == 4 => {
            let arr: [u8; 4] = bytes.as_slice().try_into().expect("length checked above");
            Ok(Some(i32::from_le_bytes(arr)))
        }
        Some(bytes) => Err(OdbcError::ValidationError(format!(
            "Integer column '{col_name}' row {row_idx}: expected 4 wire bytes, got {}",
            bytes.len()
        ))),
    }
}

fn decode_bigint_cell(
    col_name: &str,
    row_idx: usize,
    cell: Option<&Vec<u8>>,
) -> Result<Option<i64>> {
    match cell {
        None => Ok(None),
        Some(bytes) if bytes.len() == 8 => {
            let arr: [u8; 8] = bytes.as_slice().try_into().expect("length checked above");
            Ok(Some(i64::from_le_bytes(arr)))
        }
        Some(bytes) => Err(OdbcError::ValidationError(format!(
            "BigInt column '{col_name}' row {row_idx}: expected 8 wire bytes, got {}",
            bytes.len()
        ))),
    }
}

pub fn row_buffer_to_columnar(buffer: &RowBuffer) -> Result<RowBufferV2> {
    let col_count = buffer.column_count();
    let mut v2 = RowBufferV2::with_capacity(col_count);
    v2.set_row_count(buffer.row_count());

    if col_count == 0 {
        return Ok(v2);
    }

    for (col_idx, col_meta) in buffer.columns.iter().enumerate() {
        let metadata = ColumnMetadata {
            name: col_meta.name.clone(),
            odbc_type: col_meta.odbc_type,
        };

        let data = match col_meta.odbc_type {
            OdbcType::Integer => {
                let mut int_data = Vec::with_capacity(buffer.row_count());
                for (row_idx, row) in buffer.rows.iter().enumerate() {
                    let cell = row.get(col_idx).and_then(|o| o.as_ref());
                    int_data.push(decode_integer_cell(&col_meta.name, row_idx, cell)?);
                }
                ColumnData::Integer(int_data)
            }
            OdbcType::BigInt => {
                let mut bigint_data = Vec::with_capacity(buffer.row_count());
                for (row_idx, row) in buffer.rows.iter().enumerate() {
                    let cell = row.get(col_idx).and_then(|o| o.as_ref());
                    bigint_data.push(decode_bigint_cell(&col_meta.name, row_idx, cell)?);
                }
                ColumnData::BigInt(bigint_data)
            }
            OdbcType::Binary => {
                let mut binary_data = Vec::with_capacity(buffer.row_count());
                for row in &buffer.rows {
                    if let Some(cell) = row.get(col_idx) {
                        binary_data.push(cell.clone());
                    } else {
                        binary_data.push(None);
                    }
                }
                ColumnData::Binary(binary_data)
            }
            _ => {
                let mut varchar_data = Vec::with_capacity(buffer.row_count());
                for row in &buffer.rows {
                    if let Some(cell) = row.get(col_idx) {
                        varchar_data.push(cell.clone());
                    } else {
                        varchar_data.push(None);
                    }
                }
                ColumnData::Varchar(varchar_data)
            }
        };

        v2.add_column(metadata, data);
    }

    Ok(v2)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::OdbcError;
    use crate::protocol::row_buffer::RowBuffer;

    #[test]
    fn test_row_buffer_to_columnar_empty() {
        let buffer = RowBuffer::new();
        let v2 = row_buffer_to_columnar(&buffer).expect("empty buffer");
        assert_eq!(v2.column_count(), 0);
        assert_eq!(v2.row_count, 0);
    }

    #[test]
    fn test_row_buffer_to_columnar_integer() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("id".to_string(), OdbcType::Integer);
        buffer.add_row(vec![Some(42i32.to_le_bytes().to_vec())]);
        buffer.add_row(vec![Some(100i32.to_le_bytes().to_vec())]);
        buffer.add_row(vec![None]);

        let v2 = row_buffer_to_columnar(&buffer).expect("integer column");
        assert_eq!(v2.column_count(), 1);
        assert_eq!(v2.row_count, 3);
        assert_eq!(v2.columns[0].metadata.name, "id");
        assert_eq!(v2.columns[0].metadata.odbc_type, OdbcType::Integer);

        match &v2.columns[0].data {
            ColumnData::Integer(values) => {
                assert_eq!(values.len(), 3);
                assert_eq!(values[0], Some(42));
                assert_eq!(values[1], Some(100));
                assert_eq!(values[2], None);
            }
            _ => panic!("Expected Integer column data"),
        }
    }

    #[test]
    fn test_row_buffer_to_columnar_bigint() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("big_id".to_string(), OdbcType::BigInt);
        buffer.add_row(vec![Some(1234567890i64.to_le_bytes().to_vec())]);
        buffer.add_row(vec![None]);

        let v2 = row_buffer_to_columnar(&buffer).expect("bigint column");
        assert_eq!(v2.column_count(), 1);
        assert_eq!(v2.row_count, 2);

        match &v2.columns[0].data {
            ColumnData::BigInt(values) => {
                assert_eq!(values.len(), 2);
                assert_eq!(values[0], Some(1234567890));
                assert_eq!(values[1], None);
            }
            _ => panic!("Expected BigInt column data"),
        }
    }

    #[test]
    fn test_row_buffer_to_columnar_varchar() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("name".to_string(), OdbcType::Varchar);
        buffer.add_row(vec![Some(b"Alice".to_vec())]);
        buffer.add_row(vec![Some(b"Bob".to_vec())]);
        buffer.add_row(vec![None]);

        let v2 = row_buffer_to_columnar(&buffer).expect("varchar column");
        assert_eq!(v2.column_count(), 1);
        assert_eq!(v2.row_count, 3);

        match &v2.columns[0].data {
            ColumnData::Varchar(values) => {
                assert_eq!(values.len(), 3);
                assert_eq!(values[0], Some(b"Alice".to_vec()));
                assert_eq!(values[1], Some(b"Bob".to_vec()));
                assert_eq!(values[2], None);
            }
            _ => panic!("Expected Varchar column data"),
        }
    }

    #[test]
    fn test_row_buffer_to_columnar_binary() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("payload".to_string(), OdbcType::Binary);
        buffer.add_row(vec![Some(vec![0x01, 0x02, 0x03])]);
        buffer.add_row(vec![None]);

        let v2 = row_buffer_to_columnar(&buffer).expect("binary column");
        assert_eq!(v2.column_count(), 1);
        assert_eq!(v2.row_count, 2);

        match &v2.columns[0].data {
            ColumnData::Binary(values) => {
                assert_eq!(values.len(), 2);
                assert_eq!(values[0], Some(vec![0x01, 0x02, 0x03]));
                assert_eq!(values[1], None);
            }
            _ => panic!("Expected Binary column data"),
        }
    }

    #[test]
    fn test_row_buffer_to_columnar_multiple_columns() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("id".to_string(), OdbcType::Integer);
        buffer.add_column("name".to_string(), OdbcType::Varchar);
        buffer.add_row(vec![
            Some(1i32.to_le_bytes().to_vec()),
            Some(b"Alice".to_vec()),
        ]);
        buffer.add_row(vec![
            Some(2i32.to_le_bytes().to_vec()),
            Some(b"Bob".to_vec()),
        ]);

        let v2 = row_buffer_to_columnar(&buffer).expect("multiple columns");
        assert_eq!(v2.column_count(), 2);
        assert_eq!(v2.row_count, 2);
        assert_eq!(v2.columns[0].metadata.name, "id");
        assert_eq!(v2.columns[1].metadata.name, "name");
    }

    #[test]
    fn test_row_buffer_to_columnar_integer_invalid_size_returns_validation_error() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("id".to_string(), OdbcType::Integer);
        buffer.add_row(vec![Some(vec![1, 2, 3])]);

        assert!(matches!(
            row_buffer_to_columnar(&buffer),
            Err(OdbcError::ValidationError(msg)) if msg.contains("expected 4 wire bytes")
        ));
    }

    #[test]
    fn test_row_buffer_to_columnar_bigint_invalid_size_returns_validation_error() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("big_id".to_string(), OdbcType::BigInt);
        buffer.add_row(vec![Some(vec![1, 2, 3, 4, 5])]);

        assert!(matches!(
            row_buffer_to_columnar(&buffer),
            Err(OdbcError::ValidationError(msg)) if msg.contains("expected 8 wire bytes")
        ));
    }

    #[test]
    fn test_row_buffer_to_columnar_non_numeric_odbc_type_uses_varchar_storage() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("d".to_string(), OdbcType::Date);
        buffer.add_row(vec![Some(b"2024-01-01".to_vec())]);

        let v2 = row_buffer_to_columnar(&buffer).expect("date as varchar storage");
        match &v2.columns[0].data {
            ColumnData::Varchar(values) => {
                assert_eq!(values.len(), 1);
                assert_eq!(values[0], Some(b"2024-01-01".to_vec()));
            }
            _ => panic!("Expected Varchar fallback column data"),
        }
    }

    #[test]
    fn test_row_buffer_to_columnar_short_row_treats_missing_cells_as_null() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("a".to_string(), OdbcType::Integer);
        buffer.add_column("b".to_string(), OdbcType::Integer);
        buffer.add_row(vec![
            Some(1i32.to_le_bytes().to_vec()),
            Some(2i32.to_le_bytes().to_vec()),
        ]);
        buffer.add_row(vec![Some(3i32.to_le_bytes().to_vec())]);

        let v2 = row_buffer_to_columnar(&buffer).expect("short row");
        match (&v2.columns[0].data, &v2.columns[1].data) {
            (ColumnData::Integer(a), ColumnData::Integer(b)) => {
                assert_eq!(a, &vec![Some(1), Some(3)]);
                assert_eq!(b, &vec![Some(2), None]);
            }
            _ => panic!("Expected two integer columns"),
        }
    }
}

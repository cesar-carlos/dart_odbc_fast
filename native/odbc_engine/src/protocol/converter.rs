use crate::protocol::columnar::{ColumnData, ColumnMetadata, RowBufferV2};
use crate::protocol::row_buffer::RowBuffer;
use crate::protocol::types::OdbcType;

pub fn row_buffer_to_columnar(buffer: &RowBuffer) -> RowBufferV2 {
    let mut v2 = RowBufferV2::new();
    v2.set_row_count(buffer.row_count());

    let col_count = buffer.column_count();
    if col_count == 0 {
        return v2;
    }

    for (col_idx, col_meta) in buffer.columns.iter().enumerate() {
        let metadata = ColumnMetadata {
            name: col_meta.name.clone(),
            odbc_type: col_meta.odbc_type,
        };

        let data = match col_meta.odbc_type {
            OdbcType::Integer => {
                let mut int_data = Vec::new();
                for row in &buffer.rows {
                    if let Some(bytes) = row.get(col_idx).and_then(|o| o.as_ref()) {
                        if bytes.len() == 4 {
                            let value =
                                i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
                            int_data.push(Some(value));
                        } else {
                            int_data.push(None);
                        }
                    } else {
                        int_data.push(None);
                    }
                }
                ColumnData::Integer(int_data)
            }
            OdbcType::BigInt => {
                let mut bigint_data = Vec::new();
                for row in &buffer.rows {
                    if let Some(bytes) = row.get(col_idx).and_then(|o| o.as_ref()) {
                        if bytes.len() == 8 {
                            let value = i64::from_le_bytes([
                                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                                bytes[6], bytes[7],
                            ]);
                            bigint_data.push(Some(value));
                        } else {
                            bigint_data.push(None);
                        }
                    } else {
                        bigint_data.push(None);
                    }
                }
                ColumnData::BigInt(bigint_data)
            }
            _ => {
                let mut varchar_data = Vec::new();
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

    v2
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::row_buffer::RowBuffer;

    #[test]
    fn test_row_buffer_to_columnar_empty() {
        let buffer = RowBuffer::new();
        let v2 = row_buffer_to_columnar(&buffer);
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

        let v2 = row_buffer_to_columnar(&buffer);
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

        let v2 = row_buffer_to_columnar(&buffer);
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

        let v2 = row_buffer_to_columnar(&buffer);
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

        let v2 = row_buffer_to_columnar(&buffer);
        assert_eq!(v2.column_count(), 2);
        assert_eq!(v2.row_count, 2);
        assert_eq!(v2.columns[0].metadata.name, "id");
        assert_eq!(v2.columns[1].metadata.name, "name");
    }

    #[test]
    fn test_row_buffer_to_columnar_integer_invalid_size() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("id".to_string(), OdbcType::Integer);
        buffer.add_row(vec![Some(vec![1, 2, 3])]); // Invalid size (3 bytes instead of 4)

        let v2 = row_buffer_to_columnar(&buffer);
        match &v2.columns[0].data {
            ColumnData::Integer(values) => {
                assert_eq!(values.len(), 1);
                assert_eq!(values[0], None); // Should be None due to invalid size
            }
            _ => panic!("Expected Integer column data"),
        }
    }

    #[test]
    fn test_row_buffer_to_columnar_bigint_invalid_size() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("big_id".to_string(), OdbcType::BigInt);
        buffer.add_row(vec![Some(vec![1, 2, 3, 4, 5])]); // Invalid size (5 bytes instead of 8)

        let v2 = row_buffer_to_columnar(&buffer);
        match &v2.columns[0].data {
            ColumnData::BigInt(values) => {
                assert_eq!(values.len(), 1);
                assert_eq!(values[0], None); // Should be None due to invalid size
            }
            _ => panic!("Expected BigInt column data"),
        }
    }
}

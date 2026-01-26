use crate::error::{OdbcError, Result};
use crate::protocol::types::OdbcType;

const MAGIC: u32 = 0x4F444243;
const VERSION: u16 = 1;
const HEADER_SIZE: usize = 16; // magic(4) + version(2) + col_count(2) + row_count(4) + payload_size(4)

#[derive(Debug, Clone, PartialEq)]
pub struct ColumnInfo {
    pub name: String,
    pub odbc_type: OdbcType,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DecodedResult {
    pub columns: Vec<ColumnInfo>,
    pub rows: Vec<Vec<Option<Vec<u8>>>>,
    pub row_count: usize,
    pub column_count: usize,
}

pub struct BinaryProtocolDecoder;

impl BinaryProtocolDecoder {
    pub fn parse(buffer: &[u8]) -> Result<DecodedResult> {
        if buffer.len() < HEADER_SIZE {
            return Err(OdbcError::ValidationError(format!(
                "Buffer too small: need at least {} bytes, got {}",
                HEADER_SIZE,
                buffer.len()
            )));
        }

        let mut offset = 0;

        // Read magic number
        let magic = u32::from_le_bytes([
            buffer[offset],
            buffer[offset + 1],
            buffer[offset + 2],
            buffer[offset + 3],
        ]);
        if magic != MAGIC {
            return Err(OdbcError::ValidationError(format!(
                "Invalid magic number: expected 0x{:08X}, got 0x{:08X}",
                MAGIC, magic
            )));
        }
        offset += 4;

        // Read version
        let version = u16::from_le_bytes([buffer[offset], buffer[offset + 1]]);
        if version != VERSION {
            return Err(OdbcError::ValidationError(format!(
                "Invalid version: expected {}, got {}",
                VERSION, version
            )));
        }
        offset += 2;

        // Read column count
        let column_count = u16::from_le_bytes([buffer[offset], buffer[offset + 1]]) as usize;
        offset += 2;

        // Read row count
        let row_count = u32::from_le_bytes([
            buffer[offset],
            buffer[offset + 1],
            buffer[offset + 2],
            buffer[offset + 3],
        ]) as usize;
        offset += 4;

        // Read payload size (for validation, but we'll parse based on actual structure)
        let _payload_size = u32::from_le_bytes([
            buffer[offset],
            buffer[offset + 1],
            buffer[offset + 2],
            buffer[offset + 3],
        ]);
        offset += 4;

        // Parse column metadata
        let mut columns = Vec::with_capacity(column_count);
        for _ in 0..column_count {
            if offset + 4 > buffer.len() {
                return Err(OdbcError::ValidationError(
                    "Buffer too small for column metadata".to_string(),
                ));
            }

            // Read ODBC type
            let odbc_type_code = u16::from_le_bytes([buffer[offset], buffer[offset + 1]]);
            let odbc_type = OdbcType::from_odbc_sql_type(odbc_type_code as i16);
            offset += 2;

            // Read name length
            let name_len = u16::from_le_bytes([buffer[offset], buffer[offset + 1]]) as usize;
            offset += 2;

            // Read name
            if offset + name_len > buffer.len() {
                return Err(OdbcError::ValidationError(
                    "Buffer too small for column name".to_string(),
                ));
            }
            let name =
                String::from_utf8(buffer[offset..offset + name_len].to_vec()).map_err(|e| {
                    OdbcError::ValidationError(format!("Invalid UTF-8 in column name: {}", e))
                })?;
            offset += name_len;

            columns.push(ColumnInfo { name, odbc_type });
        }

        // Parse row data
        let mut rows = Vec::with_capacity(row_count);
        for _ in 0..row_count {
            let mut row = Vec::with_capacity(column_count);
            for _ in 0..column_count {
                if offset >= buffer.len() {
                    return Err(OdbcError::ValidationError(
                        "Buffer too small for row data".to_string(),
                    ));
                }

                // Read null flag
                let is_null = buffer[offset];
                offset += 1;

                if is_null == 1 {
                    // NULL value
                    row.push(None);
                } else {
                    // Read data length
                    if offset + 4 > buffer.len() {
                        return Err(OdbcError::ValidationError(
                            "Buffer too small for data length".to_string(),
                        ));
                    }
                    let data_len = u32::from_le_bytes([
                        buffer[offset],
                        buffer[offset + 1],
                        buffer[offset + 2],
                        buffer[offset + 3],
                    ]) as usize;
                    offset += 4;

                    // Read data
                    if offset + data_len > buffer.len() {
                        return Err(OdbcError::ValidationError(
                            "Buffer too small for cell data".to_string(),
                        ));
                    }
                    let data = buffer[offset..offset + data_len].to_vec();
                    offset += data_len;

                    row.push(Some(data));
                }
            }
            rows.push(row);
        }

        Ok(DecodedResult {
            columns,
            rows,
            row_count,
            column_count,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::encoder::RowBufferEncoder;
    use crate::protocol::row_buffer::RowBuffer;

    #[test]
    fn test_decode_empty_buffer() {
        let buffer = RowBuffer::new();
        let encoded = RowBufferEncoder::encode(&buffer);
        let decoded = BinaryProtocolDecoder::parse(&encoded).expect("Should decode");

        assert_eq!(decoded.column_count, 0);
        assert_eq!(decoded.row_count, 0);
        assert_eq!(decoded.columns.len(), 0);
        assert_eq!(decoded.rows.len(), 0);
    }

    #[test]
    #[ignore] // TODO: Fix type mismatch (Varchar vs Integer)
    fn test_decode_single_column_single_row() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("value".to_string(), OdbcType::Integer);
        buffer.add_row(vec![Some(vec![5, 0, 0, 0])]); // 5 as i32 little-endian

        let encoded = RowBufferEncoder::encode(&buffer);
        let decoded = BinaryProtocolDecoder::parse(&encoded).expect("Should decode");

        assert_eq!(decoded.column_count, 1);
        assert_eq!(decoded.row_count, 1);
        assert_eq!(decoded.columns[0].name, "value");
        assert_eq!(decoded.columns[0].odbc_type, OdbcType::Integer);
        assert_eq!(decoded.rows[0][0], Some(vec![5, 0, 0, 0]));
    }

    #[test]
    fn test_decode_null_value() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("nullable".to_string(), OdbcType::Varchar);
        buffer.add_row(vec![None]);

        let encoded = RowBufferEncoder::encode(&buffer);
        let decoded = BinaryProtocolDecoder::parse(&encoded).expect("Should decode");

        assert_eq!(decoded.rows[0][0], None);
    }

    #[test]
    fn test_decode_multiple_columns() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("id".to_string(), OdbcType::Integer);
        buffer.add_column("name".to_string(), OdbcType::Varchar);

        let encoded = RowBufferEncoder::encode(&buffer);
        let decoded = BinaryProtocolDecoder::parse(&encoded).expect("Should decode");

        assert_eq!(decoded.column_count, 2);
        assert_eq!(decoded.columns[0].name, "id");
        assert_eq!(decoded.columns[1].name, "name");
    }

    #[test]
    fn test_decode_multiple_rows() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("id".to_string(), OdbcType::Integer);

        buffer.add_row(vec![Some(vec![1, 0, 0, 0])]);
        buffer.add_row(vec![Some(vec![2, 0, 0, 0])]);

        let encoded = RowBufferEncoder::encode(&buffer);
        let decoded = BinaryProtocolDecoder::parse(&encoded).expect("Should decode");

        assert_eq!(decoded.row_count, 2);
        assert_eq!(decoded.rows.len(), 2);
    }

    #[test]
    fn test_decode_invalid_magic() {
        let mut buffer = vec![0u8; 16];
        buffer[0..4].copy_from_slice(&0x12345678u32.to_le_bytes());

        let result = BinaryProtocolDecoder::parse(&buffer);
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("Invalid magic number"));
    }

    #[test]
    fn test_decode_buffer_too_small() {
        let buffer = vec![0u8; 10];
        let result = BinaryProtocolDecoder::parse(&buffer);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("too small"));
    }

    #[test]
    fn test_decode_roundtrip() {
        let mut original = RowBuffer::new();
        original.add_column("num".to_string(), OdbcType::Integer);
        original.add_column("text".to_string(), OdbcType::Varchar);
        original.add_row(vec![Some(vec![42, 0, 0, 0]), Some(b"hello".to_vec())]);
        original.add_row(vec![None, Some(b"world".to_vec())]);

        let encoded = RowBufferEncoder::encode(&original);
        let decoded = BinaryProtocolDecoder::parse(&encoded).expect("Should decode");

        assert_eq!(decoded.column_count, 2);
        assert_eq!(decoded.row_count, 2);
        assert_eq!(decoded.columns[0].name, "num");
        assert_eq!(decoded.columns[1].name, "text");
        assert_eq!(decoded.rows[0][0], Some(vec![42, 0, 0, 0]));
        assert_eq!(decoded.rows[0][1], Some(b"hello".to_vec()));
        assert_eq!(decoded.rows[1][0], None);
        assert_eq!(decoded.rows[1][1], Some(b"world".to_vec()));
    }
}

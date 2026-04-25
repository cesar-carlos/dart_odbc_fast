use crate::error::{OdbcError, Result};
use crate::protocol::types::OdbcType;

const MAGIC: u32 = 0x4F444243;
const VERSION: u16 = 1;
const HEADER_SIZE: usize = 16; // magic(4) + version(2) + col_count(2) + row_count(4) + payload_size(4)
const MAX_DECODED_COLUMNS: usize = 4096;
const MAX_DECODED_ROWS: usize = 1_000_000;
const MAX_DECODED_CELLS: usize = 5_000_000;
const MAX_DECODED_PAYLOAD_SIZE: usize = 256 * 1024 * 1024;
const MAX_DECODED_CELL_SIZE: usize = 64 * 1024 * 1024;

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

        let payload_size = u32::from_le_bytes([
            buffer[offset],
            buffer[offset + 1],
            buffer[offset + 2],
            buffer[offset + 3],
        ]) as usize;
        offset += 4;

        validate_shape(column_count, row_count, payload_size)?;

        // Parse column metadata
        let mut columns = Vec::with_capacity(column_count);
        for _ in 0..column_count {
            if offset + 4 > buffer.len() {
                return Err(OdbcError::ValidationError(
                    "Buffer too small for column metadata".to_string(),
                ));
            }

            // Read ODBC type (protocol uses enum discriminant, not ODBC SQL type)
            let odbc_type_code = u16::from_le_bytes([buffer[offset], buffer[offset + 1]]);
            let odbc_type = OdbcType::from_protocol_discriminant(odbc_type_code);
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
                    if data_len > MAX_DECODED_CELL_SIZE {
                        return Err(OdbcError::ValidationError(format!(
                            "Cell data length {} exceeds limit {}",
                            data_len, MAX_DECODED_CELL_SIZE
                        )));
                    }
                    offset += 4;

                    // Read data
                    let end = offset.checked_add(data_len).ok_or_else(|| {
                        OdbcError::ValidationError("Cell data offset overflow".to_string())
                    })?;
                    if end > buffer.len() {
                        return Err(OdbcError::ValidationError(
                            "Buffer too small for cell data".to_string(),
                        ));
                    }
                    let data = buffer[offset..end].to_vec();
                    offset = end;

                    row.push(Some(data));
                }
            }
            rows.push(row);
        }

        let expected_len = HEADER_SIZE
            .checked_add(payload_size)
            .ok_or_else(|| OdbcError::ValidationError("Payload size overflow".to_string()))?;
        if expected_len != buffer.len() {
            return Err(OdbcError::ValidationError(format!(
                "Payload size mismatch: header declares {}, buffer has {} payload bytes",
                payload_size,
                buffer.len().saturating_sub(HEADER_SIZE)
            )));
        }
        if offset != buffer.len() {
            return Err(OdbcError::ValidationError(
                "Buffer has trailing bytes".to_string(),
            ));
        }

        Ok(DecodedResult {
            columns,
            rows,
            row_count,
            column_count,
        })
    }
}

fn validate_shape(column_count: usize, row_count: usize, payload_size: usize) -> Result<()> {
    if column_count > MAX_DECODED_COLUMNS {
        return Err(OdbcError::ValidationError(format!(
            "Column count {} exceeds limit {}",
            column_count, MAX_DECODED_COLUMNS
        )));
    }
    if row_count > MAX_DECODED_ROWS {
        return Err(OdbcError::ValidationError(format!(
            "Row count {} exceeds limit {}",
            row_count, MAX_DECODED_ROWS
        )));
    }
    let cell_count = column_count
        .checked_mul(row_count)
        .ok_or_else(|| OdbcError::ValidationError("Cell count overflow".to_string()))?;
    if cell_count > MAX_DECODED_CELLS {
        return Err(OdbcError::ValidationError(format!(
            "Cell count {} exceeds limit {}",
            cell_count, MAX_DECODED_CELLS
        )));
    }
    if payload_size > MAX_DECODED_PAYLOAD_SIZE {
        return Err(OdbcError::ValidationError(format!(
            "Payload size {} exceeds limit {}",
            payload_size, MAX_DECODED_PAYLOAD_SIZE
        )));
    }
    Ok(())
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

    #[test]
    fn test_decode_invalid_version() {
        let mut buffer = vec![0u8; 16];
        buffer[0..4].copy_from_slice(&0x4F444243u32.to_le_bytes());
        buffer[4..6].copy_from_slice(&999u16.to_le_bytes());

        let result = BinaryProtocolDecoder::parse(&buffer);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("Invalid version"));
    }

    #[test]
    fn test_decode_rejects_payload_size_mismatch() {
        let mut buffer = RowBufferEncoder::encode(&RowBuffer::new());
        buffer.extend_from_slice(&[1, 2, 3]);

        let result = BinaryProtocolDecoder::parse(&buffer);

        assert!(result
            .unwrap_err()
            .to_string()
            .contains("Payload size mismatch"));
    }

    #[test]
    fn test_decode_rejects_huge_row_count_before_allocation() {
        let mut buffer = vec![0u8; HEADER_SIZE];
        buffer[0..4].copy_from_slice(&MAGIC.to_le_bytes());
        buffer[4..6].copy_from_slice(&VERSION.to_le_bytes());
        buffer[6..8].copy_from_slice(&1u16.to_le_bytes());
        buffer[8..12].copy_from_slice(&u32::MAX.to_le_bytes());

        let result = BinaryProtocolDecoder::parse(&buffer);

        assert!(result.unwrap_err().to_string().contains("Row count"));
    }

    #[test]
    fn test_decode_buffer_too_small_for_column_metadata() {
        let mut buffer = vec![0u8; 17];
        buffer[0..4].copy_from_slice(&0x4F444243u32.to_le_bytes());
        buffer[4..6].copy_from_slice(&1u16.to_le_bytes());
        buffer[6..8].copy_from_slice(&1u16.to_le_bytes());
        buffer[8..12].copy_from_slice(&0u32.to_le_bytes());
        buffer[12..16].copy_from_slice(&0u32.to_le_bytes());
        buffer[16] = 0;

        let result = BinaryProtocolDecoder::parse(&buffer);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("column metadata"));
    }

    #[test]
    fn test_decode_buffer_too_small_for_column_name() {
        let mut buffer = vec![0u8; 21];
        buffer[0..4].copy_from_slice(&0x4F444243u32.to_le_bytes());
        buffer[4..6].copy_from_slice(&1u16.to_le_bytes());
        buffer[6..8].copy_from_slice(&1u16.to_le_bytes());
        buffer[8..12].copy_from_slice(&1u32.to_le_bytes());
        buffer[12..16].copy_from_slice(&10u32.to_le_bytes());
        buffer[16..18].copy_from_slice(&1u16.to_le_bytes());
        buffer[18..20].copy_from_slice(&10u16.to_le_bytes());
        buffer[20] = b'a';

        let result = BinaryProtocolDecoder::parse(&buffer);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("column name"));
    }

    #[test]
    fn test_decode_invalid_utf8_in_column_name() {
        let mut buffer = vec![0u8; 23];
        buffer[0..4].copy_from_slice(&0x4F444243u32.to_le_bytes());
        buffer[4..6].copy_from_slice(&1u16.to_le_bytes());
        buffer[6..8].copy_from_slice(&1u16.to_le_bytes());
        buffer[8..12].copy_from_slice(&1u32.to_le_bytes());
        buffer[12..16].copy_from_slice(&2u32.to_le_bytes());
        buffer[16..18].copy_from_slice(&1u16.to_le_bytes());
        buffer[18..20].copy_from_slice(&2u16.to_le_bytes());
        buffer[20] = 0xFF;
        buffer[21] = 0xFE;

        let result = BinaryProtocolDecoder::parse(&buffer);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("UTF-8"));
    }

    #[test]
    fn test_decode_buffer_too_small_for_data_length() {
        let mut buffer = vec![0u8; 22];
        buffer[0..4].copy_from_slice(&0x4F444243u32.to_le_bytes());
        buffer[4..6].copy_from_slice(&1u16.to_le_bytes());
        buffer[6..8].copy_from_slice(&1u16.to_le_bytes());
        buffer[8..12].copy_from_slice(&1u32.to_le_bytes());
        buffer[12..16].copy_from_slice(&100u32.to_le_bytes());
        buffer[16..18].copy_from_slice(&1u16.to_le_bytes());
        buffer[18..20].copy_from_slice(&1u16.to_le_bytes());
        buffer[20] = b'a';
        buffer[21] = 0;

        let result = BinaryProtocolDecoder::parse(&buffer);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("data length"));
    }

    #[test]
    fn test_decode_buffer_too_small_for_cell_data() {
        let mut buffer = vec![0u8; 26];
        buffer[0..4].copy_from_slice(&0x4F444243u32.to_le_bytes());
        buffer[4..6].copy_from_slice(&1u16.to_le_bytes());
        buffer[6..8].copy_from_slice(&1u16.to_le_bytes());
        buffer[8..12].copy_from_slice(&1u32.to_le_bytes());
        buffer[12..16].copy_from_slice(&10u32.to_le_bytes());
        buffer[16..18].copy_from_slice(&1u16.to_le_bytes());
        buffer[18..20].copy_from_slice(&1u16.to_le_bytes());
        buffer[20] = b'a';
        buffer[21] = 0;
        buffer[22..26].copy_from_slice(&2u32.to_le_bytes());

        let result = BinaryProtocolDecoder::parse(&buffer);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("cell data"));
    }

    #[test]
    fn test_decode_buffer_too_small_for_row_data() {
        let mut buffer = vec![0u8; 21];
        buffer[0..4].copy_from_slice(&0x4F444243u32.to_le_bytes());
        buffer[4..6].copy_from_slice(&1u16.to_le_bytes());
        buffer[6..8].copy_from_slice(&1u16.to_le_bytes());
        buffer[8..12].copy_from_slice(&1u32.to_le_bytes());
        buffer[12..16].copy_from_slice(&1u32.to_le_bytes());
        buffer[16..18].copy_from_slice(&1u16.to_le_bytes());
        buffer[18..20].copy_from_slice(&1u16.to_le_bytes());
        buffer[20] = b'a';

        let result = BinaryProtocolDecoder::parse(&buffer);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("row data"));
    }

    /// `validate_shape` — column count cap before allocating metadata.
    #[test]
    fn test_decode_rejects_column_count_over_limit() {
        let mut buffer = vec![0u8; HEADER_SIZE];
        buffer[0..4].copy_from_slice(&MAGIC.to_le_bytes());
        buffer[4..6].copy_from_slice(&VERSION.to_le_bytes());
        buffer[6..8].copy_from_slice(&(MAX_DECODED_COLUMNS as u16 + 1).to_le_bytes());
        buffer[8..12].copy_from_slice(&0u32.to_le_bytes());
        buffer[12..16].copy_from_slice(&0u32.to_le_bytes());

        let err = BinaryProtocolDecoder::parse(&buffer).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("Column count"), "got {msg}");
        assert!(msg.contains("4096"), "got {msg}");
    }

    /// `validate_shape` — cell count cap.
    #[test]
    fn test_decode_rejects_cell_count_over_limit() {
        let col = 2_500u16;
        let row = 2_001u32;
        assert!(col as usize * row as usize > MAX_DECODED_CELLS);
        let mut buffer = vec![0u8; HEADER_SIZE];
        buffer[0..4].copy_from_slice(&MAGIC.to_le_bytes());
        buffer[4..6].copy_from_slice(&VERSION.to_le_bytes());
        buffer[6..8].copy_from_slice(&col.to_le_bytes());
        buffer[8..12].copy_from_slice(&row.to_le_bytes());
        buffer[12..16].copy_from_slice(&0u32.to_le_bytes());

        let err = BinaryProtocolDecoder::parse(&buffer).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("Cell count"), "got {msg}");
    }

    /// `validate_shape` — declared payload size cap.
    #[test]
    fn test_decode_rejects_payload_size_over_limit() {
        let mut buffer = vec![0u8; HEADER_SIZE];
        buffer[0..4].copy_from_slice(&MAGIC.to_le_bytes());
        buffer[4..6].copy_from_slice(&VERSION.to_le_bytes());
        buffer[6..8].copy_from_slice(&0u16.to_le_bytes());
        buffer[8..12].copy_from_slice(&0u32.to_le_bytes());
        buffer[12..16].copy_from_slice(&(MAX_DECODED_PAYLOAD_SIZE as u32 + 1).to_le_bytes());

        let err = BinaryProtocolDecoder::parse(&buffer).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("Payload size"), "got {msg}");
    }

    /// Per-cell `data_len` must not exceed [MAX_DECODED_CELL_SIZE].
    #[test]
    fn test_decode_rejects_oversized_cell_data_length() {
        // Wire: odbc type (2) + name_len (2) + name (0) + null flag (1) + data_len (4)
        const PAYLOAD: usize = 2 + 2 + 1 + 4;
        let mut buffer = vec![0u8; HEADER_SIZE + PAYLOAD];
        buffer[0..4].copy_from_slice(&MAGIC.to_le_bytes());
        buffer[4..6].copy_from_slice(&VERSION.to_le_bytes());
        buffer[6..8].copy_from_slice(&1u16.to_le_bytes());
        buffer[8..12].copy_from_slice(&1u32.to_le_bytes());
        buffer[12..16].copy_from_slice(&(PAYLOAD as u32).to_le_bytes());
        let o = 16;
        buffer[o..o + 2].copy_from_slice(&2u16.to_le_bytes());
        buffer[o + 2..o + 4].copy_from_slice(&0u16.to_le_bytes());
        buffer[o + 4] = 0;
        let bad_len = (MAX_DECODED_CELL_SIZE as u32).saturating_add(1);
        buffer[o + 5..o + 9].copy_from_slice(&bad_len.to_le_bytes());

        let err = BinaryProtocolDecoder::parse(&buffer).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("Cell data length"), "got {msg}");
    }
}

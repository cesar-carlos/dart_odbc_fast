use crate::protocol::compression::CompressionStrategy;
use crate::protocol::row_buffer::RowBuffer;

const MAGIC: u32 = 0x4F444243;
const VERSION: u16 = 1;

pub struct RowBufferEncoder;

impl RowBufferEncoder {
    pub fn encode(buffer: &RowBuffer) -> Vec<u8> {
        let mut output = Vec::new();

        let mut metadata_size = 0;
        for col in &buffer.columns {
            metadata_size += 2 + 2 + col.name.len();
        }

        let mut payload_size = metadata_size;
        for row in &buffer.rows {
            for cell in row {
                payload_size += 1;
                if let Some(data) = cell {
                    payload_size += 4 + data.len();
                }
            }
        }

        output.extend_from_slice(&MAGIC.to_le_bytes());
        output.extend_from_slice(&VERSION.to_le_bytes());
        output.extend_from_slice(&(buffer.column_count() as u16).to_le_bytes());
        output.extend_from_slice(&(buffer.row_count() as u32).to_le_bytes());
        output.extend_from_slice(&(payload_size as u32).to_le_bytes());

        for col in &buffer.columns {
            output.extend_from_slice(&(col.odbc_type as u16).to_le_bytes());
            output.extend_from_slice(&(col.name.len() as u16).to_le_bytes());
            output.extend_from_slice(col.name.as_bytes());
        }

        for row in &buffer.rows {
            for cell in row {
                if let Some(data) = cell {
                    output.push(0);
                    output.extend_from_slice(&(data.len() as u32).to_le_bytes());
                    output.extend_from_slice(data);
                } else {
                    output.push(1);
                }
            }
        }

        output
    }

    /// Encode then optionally compress when payload exceeds 1MB.
    pub fn encode_with_compression(buffer: &RowBuffer) -> Vec<u8> {
        let raw = Self::encode(buffer);
        let strategy = CompressionStrategy::auto_select(raw.len());
        strategy.compress(&raw).unwrap_or(raw)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::types::OdbcType;

    #[test]
    fn test_encode_empty_buffer() {
        let buffer = RowBuffer::new();
        let encoded = RowBufferEncoder::encode(&buffer);

        // Header: magic(4) + version(2) + col_count(2) + row_count(4) + payload_size(4) = 16 bytes
        assert_eq!(encoded.len(), 16);

        // Verify magic
        let magic = u32::from_le_bytes([encoded[0], encoded[1], encoded[2], encoded[3]]);
        assert_eq!(magic, MAGIC);

        // Verify version
        let version = u16::from_le_bytes([encoded[4], encoded[5]]);
        assert_eq!(version, VERSION);

        // Verify column count
        let col_count = u16::from_le_bytes([encoded[6], encoded[7]]);
        assert_eq!(col_count, 0);

        // Verify row count
        let row_count = u32::from_le_bytes([encoded[8], encoded[9], encoded[10], encoded[11]]);
        assert_eq!(row_count, 0);
    }

    #[test]
    fn test_encode_single_column_no_rows() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("id".to_string(), OdbcType::Integer);

        let encoded = RowBufferEncoder::encode(&buffer);

        // Header(16) + column_metadata(2 + 2 + 2) = 22 bytes
        assert_eq!(encoded.len(), 22);

        // Verify column count
        let col_count = u16::from_le_bytes([encoded[6], encoded[7]]);
        assert_eq!(col_count, 1);

        // Verify column type
        let col_type = u16::from_le_bytes([encoded[16], encoded[17]]);
        assert_eq!(col_type, OdbcType::Integer as u16);

        // Verify column name length
        let name_len = u16::from_le_bytes([encoded[18], encoded[19]]);
        assert_eq!(name_len, 2);

        // Verify column name
        assert_eq!(&encoded[20..22], b"id");
    }

    #[test]
    fn test_encode_single_row_single_column() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("value".to_string(), OdbcType::Varchar);
        buffer.add_row(vec![Some(b"test".to_vec())]);

        let encoded = RowBufferEncoder::encode(&buffer);

        // Verify row count
        let row_count = u32::from_le_bytes([encoded[8], encoded[9], encoded[10], encoded[11]]);
        assert_eq!(row_count, 1);

        // Find row data (after header and metadata)
        let metadata_offset = 16; // header
        let col_type = u16::from_le_bytes([encoded[metadata_offset], encoded[metadata_offset + 1]]);
        assert_eq!(col_type, OdbcType::Varchar as u16);

        let name_len =
            u16::from_le_bytes([encoded[metadata_offset + 2], encoded[metadata_offset + 3]])
                as usize;
        let row_data_offset = metadata_offset + 4 + name_len;

        // Verify cell is not null
        assert_eq!(encoded[row_data_offset], 0);

        // Verify data length
        let data_len = u32::from_le_bytes([
            encoded[row_data_offset + 1],
            encoded[row_data_offset + 2],
            encoded[row_data_offset + 3],
            encoded[row_data_offset + 4],
        ]) as usize;
        assert_eq!(data_len, 4);

        // Verify data
        assert_eq!(
            &encoded[row_data_offset + 5..row_data_offset + 5 + data_len],
            b"test"
        );
    }

    #[test]
    fn test_encode_null_value() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("nullable".to_string(), OdbcType::Varchar);
        buffer.add_row(vec![None]);

        let encoded = RowBufferEncoder::encode(&buffer);

        // Find row data offset
        let metadata_offset = 16;
        let name_len =
            u16::from_le_bytes([encoded[metadata_offset + 2], encoded[metadata_offset + 3]])
                as usize;
        let row_data_offset = metadata_offset + 4 + name_len;

        // Verify cell is null (flag = 1)
        assert_eq!(encoded[row_data_offset], 1);

        // No data length or data for null cells
        assert_eq!(encoded.len(), row_data_offset + 1);
    }

    #[test]
    fn test_encode_multiple_columns() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("id".to_string(), OdbcType::Integer);
        buffer.add_column("name".to_string(), OdbcType::Varchar);
        buffer.add_column("age".to_string(), OdbcType::Integer);

        let encoded = RowBufferEncoder::encode(&buffer);

        // Verify column count
        let col_count = u16::from_le_bytes([encoded[6], encoded[7]]);
        assert_eq!(col_count, 3);
    }

    #[test]
    fn test_encode_with_compression_small() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("x".to_string(), OdbcType::Integer);
        buffer.add_row(vec![Some(vec![1, 0, 0, 0])]);
        let out = RowBufferEncoder::encode_with_compression(&buffer);
        let raw = RowBufferEncoder::encode(&buffer);
        assert_eq!(out, raw);
    }

    #[test]
    fn test_encode_multiple_rows() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("id".to_string(), OdbcType::Integer);

        buffer.add_row(vec![Some(vec![1, 0, 0, 0])]);
        buffer.add_row(vec![Some(vec![2, 0, 0, 0])]);
        buffer.add_row(vec![Some(vec![3, 0, 0, 0])]);

        let encoded = RowBufferEncoder::encode(&buffer);

        // Verify row count
        let row_count = u32::from_le_bytes([encoded[8], encoded[9], encoded[10], encoded[11]]);
        assert_eq!(row_count, 3);
    }

    #[test]
    fn test_encode_mixed_null_and_data() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("col1".to_string(), OdbcType::Varchar);
        buffer.add_column("col2".to_string(), OdbcType::Varchar);

        buffer.add_row(vec![Some(b"A".to_vec()), None]);
        buffer.add_row(vec![None, Some(b"B".to_vec())]);

        let encoded = RowBufferEncoder::encode(&buffer);

        // Verify structure exists (detailed parsing skipped for brevity)
        assert!(encoded.len() > 16); // Has header + data
    }

    #[test]
    fn test_magic_constant() {
        assert_eq!(MAGIC, 0x4F444243); // "ODBC" in ASCII
    }

    #[test]
    fn test_version_constant() {
        assert_eq!(VERSION, 1);
    }
}

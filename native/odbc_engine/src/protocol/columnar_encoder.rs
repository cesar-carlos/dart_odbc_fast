use crate::error::{OdbcError, Result};
use crate::protocol::columnar::{ColumnBlock, ColumnData, CompressionType, RowBufferV2};
use crate::protocol::converter::row_buffer_to_columnar;
use crate::protocol::row_buffer::RowBuffer;
use std::io::Write;

const MAGIC: u32 = 0x4F444243;
const VERSION_V2: u16 = 2;

/// Minimum raw column payload size in bytes required to attempt zstd compression.
///
/// Payloads at or below this threshold are stored uncompressed because the
/// zstd frame overhead would exceed any transfer savings for small columns.
pub const COMPRESSION_THRESHOLD_BYTES: usize = 1024;

pub struct ColumnarEncoder;

impl ColumnarEncoder {
    pub fn encode(buffer: &RowBufferV2, use_compression: bool) -> Result<Vec<u8>> {
        let mut output = Vec::with_capacity(Self::estimate_encoded_size(buffer)?);

        output.extend_from_slice(&MAGIC.to_le_bytes());
        output.extend_from_slice(&VERSION_V2.to_le_bytes());
        output.extend_from_slice(&buffer.flags.to_le_bytes());
        output
            .extend_from_slice(&checked_u16(buffer.column_count(), "column count")?.to_le_bytes());
        output.extend_from_slice(&checked_u32(buffer.row_count, "row count")?.to_le_bytes());

        let compression_flag = if use_compression { 1u8 } else { 0u8 };
        output.push(compression_flag);

        let payload_size_pos = output.len();
        output.extend_from_slice(&0u32.to_le_bytes());

        let payload_start = output.len();

        for col_block in &buffer.columns {
            Self::encode_column_block(&mut output, col_block, use_compression)?;
        }

        let payload_size = checked_u32(output.len() - payload_start, "payload size")?;
        let payload_size_bytes = payload_size.to_le_bytes();
        output[payload_size_pos..payload_size_pos + 4].copy_from_slice(&payload_size_bytes);

        Ok(output)
    }

    fn encode_column_block(
        output: &mut Vec<u8>,
        col_block: &ColumnBlock,
        use_compression: bool,
    ) -> Result<()> {
        let col_name_bytes = col_block.metadata.name.as_bytes();
        output.extend_from_slice(&(col_block.metadata.odbc_type as u16).to_le_bytes());
        output.extend_from_slice(
            &checked_u16(col_name_bytes.len(), "column name length")?.to_le_bytes(),
        );
        output.extend_from_slice(col_name_bytes);

        let raw_payload_size = Self::estimate_column_payload_size(col_block)?;
        // Skip compression for small payloads where zstd overhead exceeds transfer savings.
        if !use_compression || raw_payload_size <= COMPRESSION_THRESHOLD_BYTES {
            output.push(0);
            output.extend_from_slice(
                &checked_u32(raw_payload_size, "column payload length")?.to_le_bytes(),
            );
            Self::encode_column_payload(output, col_block)?;
            return Ok(());
        }

        let compress_attempt_start = output.len();
        output.push(1);
        output.push(CompressionType::Zstd as u8);
        let payload_len_pos = output.len();
        output.extend_from_slice(&0u32.to_le_bytes());
        let compressed_data_start = output.len();

        let compression_result = (|| -> std::io::Result<()> {
            let mut encoder = zstd::Encoder::new(&mut *output, 3)
                .map_err(|e| std::io::Error::other(e.to_string()))?;
            Self::encode_column_payload(&mut encoder, col_block)
                .map_err(|e| std::io::Error::other(e.to_string()))?;
            encoder
                .finish()
                .map(|_| ())
                .map_err(|e| std::io::Error::other(e.to_string()))?;
            Ok(())
        })();

        match compression_result {
            Ok(()) => {
                let compressed_len = output.len() - compressed_data_start;
                if compressed_len < raw_payload_size {
                    let len_bytes =
                        checked_u32(compressed_len, "column payload length")?.to_le_bytes();
                    output[payload_len_pos..payload_len_pos + 4].copy_from_slice(&len_bytes);
                    return Ok(());
                }
                output.truncate(compress_attempt_start);
            }
            Err(_) => {
                output.truncate(compress_attempt_start);
            }
        }

        output.push(0);
        output.extend_from_slice(
            &checked_u32(raw_payload_size, "column payload length")?.to_le_bytes(),
        );
        Self::encode_column_payload(output, col_block)?;

        Ok(())
    }

    fn encode_column_payload<W: Write>(output: &mut W, col_block: &ColumnBlock) -> Result<()> {
        match &col_block.data {
            ColumnData::Varchar(data) => {
                for cell in data {
                    if let Some(bytes) = cell {
                        output.write_all(&[0]).map_err(io_to_odbc)?;
                        output
                            .write_all(
                                &checked_u32(bytes.len(), "varchar cell length")?.to_le_bytes(),
                            )
                            .map_err(io_to_odbc)?;
                        output.write_all(bytes).map_err(io_to_odbc)?;
                    } else {
                        output.write_all(&[1]).map_err(io_to_odbc)?;
                    }
                }
            }
            ColumnData::Integer(data) => {
                for cell in data {
                    if let Some(value) = cell {
                        output.write_all(&[0]).map_err(io_to_odbc)?;
                        output.write_all(&value.to_le_bytes()).map_err(io_to_odbc)?;
                    } else {
                        output.write_all(&[1]).map_err(io_to_odbc)?;
                    }
                }
            }
            ColumnData::BigInt(data) => {
                for cell in data {
                    if let Some(value) = cell {
                        output.write_all(&[0]).map_err(io_to_odbc)?;
                        output.write_all(&value.to_le_bytes()).map_err(io_to_odbc)?;
                    } else {
                        output.write_all(&[1]).map_err(io_to_odbc)?;
                    }
                }
            }
            ColumnData::Binary(data) => {
                for cell in data {
                    if let Some(bytes) = cell {
                        output.write_all(&[0]).map_err(io_to_odbc)?;
                        output
                            .write_all(
                                &checked_u32(bytes.len(), "binary cell length")?.to_le_bytes(),
                            )
                            .map_err(io_to_odbc)?;
                        output.write_all(bytes).map_err(io_to_odbc)?;
                    } else {
                        output.write_all(&[1]).map_err(io_to_odbc)?;
                    }
                }
            }
        }
        Ok(())
    }

    fn estimate_encoded_size(buffer: &RowBufferV2) -> Result<usize> {
        const HEADER_SIZE: usize = 19;
        let mut size = HEADER_SIZE;
        for col_block in &buffer.columns {
            size = checked_add(size, 2, "column type")?;
            size = checked_add(size, 2, "column name length")?;
            size = checked_add(size, col_block.metadata.name.len(), "column name")?;
            size = checked_add(size, 1, "compression flag")?;
            size = checked_add(size, 1, "compression algorithm")?;
            size = checked_add(size, 4, "column payload length")?;
            size = checked_add(
                size,
                Self::estimate_column_payload_size(col_block)?,
                "column payload",
            )?;
        }
        Ok(size)
    }

    fn estimate_column_payload_size(col_block: &ColumnBlock) -> Result<usize> {
        let mut size = 0usize;
        match &col_block.data {
            ColumnData::Varchar(data) | ColumnData::Binary(data) => {
                for cell in data {
                    size = checked_add(size, 1, "cell null flag")?;
                    if let Some(bytes) = cell {
                        checked_u32(bytes.len(), "cell length")?;
                        size = checked_add(size, 4, "cell length")?;
                        size = checked_add(size, bytes.len(), "cell payload")?;
                    }
                }
            }
            ColumnData::Integer(data) => {
                for cell in data {
                    size = checked_add(size, 1, "cell null flag")?;
                    if cell.is_some() {
                        size = checked_add(size, 4, "integer cell")?;
                    }
                }
            }
            ColumnData::BigInt(data) => {
                for cell in data {
                    size = checked_add(size, 1, "cell null flag")?;
                    if cell.is_some() {
                        size = checked_add(size, 8, "bigint cell")?;
                    }
                }
            }
        }
        Ok(size)
    }

    /// Encode row-oriented buffer for bulk operations: transpose to columnar,
    /// then encode with compression. Optimal for analytical workloads.
    pub fn encode_for_bulk(buffer: RowBuffer) -> Result<Vec<u8>> {
        let columnar = row_buffer_to_columnar(buffer)?;
        Self::encode(&columnar, true)
    }
}

fn io_to_odbc(err: std::io::Error) -> OdbcError {
    OdbcError::InternalError(format!("columnar encode write failed: {err}"))
}

fn checked_u16(value: usize, field: &'static str) -> Result<u16> {
    value.try_into().map_err(|_| {
        OdbcError::ResourceLimitReached(format!("{} {} exceeds u16 wire limit", field, value))
    })
}

fn checked_u32(value: usize, field: &'static str) -> Result<u32> {
    value.try_into().map_err(|_| {
        OdbcError::ResourceLimitReached(format!("{} {} exceeds u32 wire limit", field, value))
    })
}

fn checked_add(current: usize, added: usize, context: &'static str) -> Result<usize> {
    current.checked_add(added).ok_or_else(|| {
        OdbcError::ResourceLimitReached(format!(
            "Columnar payload size overflow while adding {}",
            context
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::columnar::{ColumnMetadata, RowBufferV2};
    use crate::protocol::types::OdbcType;

    #[test]
    fn test_encode_empty_buffer() {
        let buffer = RowBufferV2::new();
        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        assert!(encoded.len() >= 17);

        let magic = u32::from_le_bytes([encoded[0], encoded[1], encoded[2], encoded[3]]);
        assert_eq!(magic, MAGIC);

        let version = u16::from_le_bytes([encoded[4], encoded[5]]);
        assert_eq!(version, VERSION_V2);

        let flags = u16::from_le_bytes([encoded[6], encoded[7]]);
        assert_eq!(flags, 0);

        let col_count = u16::from_le_bytes([encoded[8], encoded[9]]);
        assert_eq!(col_count, 0);

        let row_count = u32::from_le_bytes([encoded[10], encoded[11], encoded[12], encoded[13]]);
        assert_eq!(row_count, 0);

        let compression_flag = encoded[14];
        assert_eq!(compression_flag, 0);

        if encoded.len() >= 19 {
            let payload_size =
                u32::from_le_bytes([encoded[15], encoded[16], encoded[17], encoded[18]]);
            assert_eq!(payload_size, 0);
        }
    }

    #[test]
    fn test_encode_single_column_no_rows() {
        let mut buffer = RowBufferV2::new();
        let metadata = ColumnMetadata {
            name: "id".to_string(),
            odbc_type: OdbcType::Integer,
        };
        let data = ColumnData::Integer(vec![]);
        buffer.add_column(metadata, data);

        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        let col_count = u16::from_le_bytes([encoded[8], encoded[9]]);
        assert_eq!(col_count, 1);

        let col_type = u16::from_le_bytes([encoded[19], encoded[20]]);
        assert_eq!(col_type, OdbcType::Integer as u16);

        let name_len = u16::from_le_bytes([encoded[21], encoded[22]]);
        assert_eq!(name_len, 2);

        let name = String::from_utf8_lossy(&encoded[23..25]);
        assert_eq!(name, "id");
    }

    #[test]
    fn test_encode_single_column_single_row_integer() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(1);
        let metadata = ColumnMetadata {
            name: "value".to_string(),
            odbc_type: OdbcType::Integer,
        };
        let data = ColumnData::Integer(vec![Some(42)]);
        buffer.add_column(metadata, data);

        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        let row_count = u32::from_le_bytes([encoded[10], encoded[11], encoded[12], encoded[13]]);
        assert_eq!(row_count, 1);

        let col_count = u16::from_le_bytes([encoded[8], encoded[9]]);
        assert_eq!(col_count, 1);

        let value_bytes = 42i32.to_le_bytes();
        assert!(encoded
            .windows(value_bytes.len())
            .any(|window| window == value_bytes));
    }

    #[test]
    fn test_encode_single_column_single_row_varchar() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(1);
        let metadata = ColumnMetadata {
            name: "name".to_string(),
            odbc_type: OdbcType::Varchar,
        };
        let data = ColumnData::Varchar(vec![Some(b"test".to_vec())]);
        buffer.add_column(metadata, data);

        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        let row_count = u32::from_le_bytes([encoded[10], encoded[11], encoded[12], encoded[13]]);
        assert_eq!(row_count, 1);

        assert!(encoded.windows(4).any(|window| window == b"test"));
    }

    #[test]
    fn test_encode_single_column_single_row_bigint() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(1);
        let metadata = ColumnMetadata {
            name: "big_value".to_string(),
            odbc_type: OdbcType::BigInt,
        };
        let data = ColumnData::BigInt(vec![Some(9223372036854775807i64)]);
        buffer.add_column(metadata, data);

        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        let row_count = u32::from_le_bytes([encoded[10], encoded[11], encoded[12], encoded[13]]);
        assert_eq!(row_count, 1);

        let value_bytes = 9223372036854775807i64.to_le_bytes();
        assert!(encoded
            .windows(value_bytes.len())
            .any(|window| window == value_bytes));
    }

    #[test]
    fn test_encode_single_column_single_row_binary() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(1);
        let metadata = ColumnMetadata {
            name: "data".to_string(),
            odbc_type: OdbcType::Binary,
        };
        let data = ColumnData::Binary(vec![Some(vec![0x01, 0x02, 0x03, 0x04])]);
        buffer.add_column(metadata, data);

        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        let row_count = u32::from_le_bytes([encoded[10], encoded[11], encoded[12], encoded[13]]);
        assert_eq!(row_count, 1);

        assert!(encoded
            .windows(4)
            .any(|window| window == [0x01, 0x02, 0x03, 0x04]));
    }

    #[test]
    fn test_encode_null_value() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(1);
        let metadata = ColumnMetadata {
            name: "nullable".to_string(),
            odbc_type: OdbcType::Integer,
        };
        let data = ColumnData::Integer(vec![None]);
        buffer.add_column(metadata, data);

        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        let row_count = u32::from_le_bytes([encoded[10], encoded[11], encoded[12], encoded[13]]);
        assert_eq!(row_count, 1);

        assert!(encoded.contains(&1u8));
    }

    #[test]
    fn test_encode_multiple_columns() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(1);

        let metadata1 = ColumnMetadata {
            name: "id".to_string(),
            odbc_type: OdbcType::Integer,
        };
        let data1 = ColumnData::Integer(vec![Some(1)]);
        buffer.add_column(metadata1, data1);

        let metadata2 = ColumnMetadata {
            name: "name".to_string(),
            odbc_type: OdbcType::Varchar,
        };
        let data2 = ColumnData::Varchar(vec![Some(b"Alice".to_vec())]);
        buffer.add_column(metadata2, data2);

        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        let col_count = u16::from_le_bytes([encoded[8], encoded[9]]);
        assert_eq!(col_count, 2);
    }

    #[test]
    fn test_encode_multiple_rows() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(3);
        let metadata = ColumnMetadata {
            name: "id".to_string(),
            odbc_type: OdbcType::Integer,
        };
        let data = ColumnData::Integer(vec![Some(1), Some(2), Some(3)]);
        buffer.add_column(metadata, data);

        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        let row_count = u32::from_le_bytes([encoded[10], encoded[11], encoded[12], encoded[13]]);
        assert_eq!(row_count, 3);
    }

    #[test]
    fn test_encode_mixed_null_and_data() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(3);
        let metadata = ColumnMetadata {
            name: "value".to_string(),
            odbc_type: OdbcType::Integer,
        };
        let data = ColumnData::Integer(vec![Some(1), None, Some(3)]);
        buffer.add_column(metadata, data);

        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        let row_count = u32::from_le_bytes([encoded[10], encoded[11], encoded[12], encoded[13]]);
        assert_eq!(row_count, 3);

        let value1_bytes = 1i32.to_le_bytes();
        let value3_bytes = 3i32.to_le_bytes();
        assert!(encoded
            .windows(value1_bytes.len())
            .any(|window| window == value1_bytes));
        assert!(encoded
            .windows(value3_bytes.len())
            .any(|window| window == value3_bytes));
    }

    #[test]
    fn test_encode_with_compression_flag_false() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(1);
        let metadata = ColumnMetadata {
            name: "data".to_string(),
            odbc_type: OdbcType::Varchar,
        };
        let data = ColumnData::Varchar(vec![Some(b"small data".to_vec())]);
        buffer.add_column(metadata, data);

        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        let compression_flag = encoded[14];
        assert_eq!(compression_flag, 0);
    }

    #[test]
    fn test_encode_with_compression_flag_true() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(1);
        let metadata = ColumnMetadata {
            name: "data".to_string(),
            odbc_type: OdbcType::Varchar,
        };
        let data = ColumnData::Varchar(vec![Some(b"small data".to_vec())]);
        buffer.add_column(metadata, data);

        let encoded = ColumnarEncoder::encode(&buffer, true).expect("Should encode");

        let compression_flag = encoded[14];
        assert_eq!(compression_flag, 1);
    }

    #[test]
    fn test_encode_with_compression_large_data() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(1);
        let metadata = ColumnMetadata {
            name: "large_data".to_string(),
            odbc_type: OdbcType::Varchar,
        };
        let large_data = vec![0u8; 200];
        let data = ColumnData::Varchar(vec![Some(large_data)]);
        buffer.add_column(metadata, data);

        let encoded = ColumnarEncoder::encode(&buffer, true).expect("Should encode");

        let compression_flag = encoded[14];
        assert_eq!(compression_flag, 1);

        assert!(encoded.len() < 250);
    }

    #[test]
    fn test_encode_with_flags() {
        let mut buffer = RowBufferV2::new();
        buffer.flags = 0x1234;
        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        let flags = u16::from_le_bytes([encoded[6], encoded[7]]);
        assert_eq!(flags, 0x1234);
    }

    #[test]
    fn test_encode_payload_size() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(1);
        let metadata = ColumnMetadata {
            name: "id".to_string(),
            odbc_type: OdbcType::Integer,
        };
        let data = ColumnData::Integer(vec![Some(42)]);
        buffer.add_column(metadata, data);

        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        let payload_size = u32::from_le_bytes([encoded[15], encoded[16], encoded[17], encoded[18]]);
        assert!(payload_size > 0);
    }

    #[test]
    fn test_encode_uncompressed_binary_equivalence() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(2);
        buffer.add_column(
            ColumnMetadata {
                name: "id".to_string(),
                odbc_type: OdbcType::Integer,
            },
            ColumnData::Integer(vec![Some(7), None]),
        );
        buffer.add_column(
            ColumnMetadata {
                name: "name".to_string(),
                odbc_type: OdbcType::Varchar,
            },
            ColumnData::Varchar(vec![Some(b"Al".to_vec()), None]),
        );

        let encoded = ColumnarEncoder::encode(&buffer, false).expect("Should encode");

        let mut expected = Vec::new();
        expected.extend_from_slice(&MAGIC.to_le_bytes());
        expected.extend_from_slice(&VERSION_V2.to_le_bytes());
        expected.extend_from_slice(&0u16.to_le_bytes());
        expected.extend_from_slice(&2u16.to_le_bytes());
        expected.extend_from_slice(&2u32.to_le_bytes());
        expected.push(0);
        expected.extend_from_slice(&38u32.to_le_bytes());

        expected.extend_from_slice(&(OdbcType::Integer as u16).to_le_bytes());
        expected.extend_from_slice(&2u16.to_le_bytes());
        expected.extend_from_slice(b"id");
        expected.push(0);
        expected.extend_from_slice(&6u32.to_le_bytes());
        expected.push(0);
        expected.extend_from_slice(&7i32.to_le_bytes());
        expected.push(1);

        expected.extend_from_slice(&(OdbcType::Varchar as u16).to_le_bytes());
        expected.extend_from_slice(&4u16.to_le_bytes());
        expected.extend_from_slice(b"name");
        expected.push(0);
        expected.extend_from_slice(&8u32.to_le_bytes());
        expected.push(0);
        expected.extend_from_slice(&2u32.to_le_bytes());
        expected.extend_from_slice(b"Al");
        expected.push(1);

        assert_eq!(encoded, expected);
    }

    #[test]
    fn checked_u16_rejects_value_above_u16_max() {
        let err = checked_u16(usize::from(u16::MAX) + 1, "column count").unwrap_err();
        assert!(matches!(err, OdbcError::ResourceLimitReached(_)));
    }

    #[test]
    fn checked_u32_rejects_value_above_u32_max() {
        let err = checked_u32(usize::MAX, "row count").unwrap_err();
        assert!(matches!(err, OdbcError::ResourceLimitReached(_)));
    }

    #[test]
    fn checked_add_rejects_usize_overflow() {
        let err = checked_add(usize::MAX, 1, "unit test").unwrap_err();
        assert!(matches!(err, OdbcError::ResourceLimitReached(_)));
    }

    #[test]
    fn encode_rejects_row_count_above_u32_wire_limit() {
        if usize::MAX <= u32::MAX as usize {
            return;
        }
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count((u32::MAX as usize).saturating_add(1));
        let err = ColumnarEncoder::encode(&buffer, false).unwrap_err();
        assert!(matches!(err, OdbcError::ResourceLimitReached(_)));
    }

    #[test]
    fn encode_rejects_column_name_byte_length_above_u16() {
        let mut buffer = RowBufferV2::new();
        let long_name = "n".repeat(usize::from(u16::MAX) + 1);
        buffer.add_column(
            ColumnMetadata {
                name: long_name,
                odbc_type: OdbcType::Varchar,
            },
            ColumnData::Varchar(vec![]),
        );
        let err = ColumnarEncoder::encode(&buffer, false).unwrap_err();
        assert!(matches!(err, OdbcError::ResourceLimitReached(_)));
    }

    #[test]
    fn compressed_output_identical_for_same_input() {
        let mut buffer = RowBufferV2::new();
        buffer.set_row_count(100);
        let large_data: Vec<u8> = (0..2048).map(|i| (i % 256) as u8).collect();
        buffer.add_column(
            ColumnMetadata {
                name: "payload".to_string(),
                odbc_type: OdbcType::Varchar,
            },
            ColumnData::Varchar(vec![Some(large_data.clone()); 100]),
        );

        let encoded1 = ColumnarEncoder::encode(&buffer, true).expect("encode 1");
        let encoded2 = ColumnarEncoder::encode(&buffer, true).expect("encode 2");
        assert_eq!(encoded1, encoded2);
        assert_eq!(encoded1[14], 1, "global compression flag should be set");
    }

    #[test]
    fn encode_for_bulk_empty_row_buffer() {
        let rb = crate::protocol::row_buffer::RowBuffer::new();
        let out = ColumnarEncoder::encode_for_bulk(rb).expect("empty bulk encode");
        let magic = u32::from_le_bytes([out[0], out[1], out[2], out[3]]);
        assert_eq!(magic, MAGIC);
    }

    #[test]
    fn encode_for_bulk_single_integer_column() {
        let mut rb = crate::protocol::row_buffer::RowBuffer::new();
        rb.add_column("n".to_string(), OdbcType::Integer);
        rb.add_row_vecs(vec![Some(42i32.to_le_bytes().to_vec())]);
        let out = ColumnarEncoder::encode_for_bulk(rb).expect("bulk");
        assert!(out.len() > 19);
        let b = 42i32.to_le_bytes();
        assert!(out.windows(4).any(|w| w == b));
    }
}

use crate::protocol::compression::CompressionStrategy;
use crate::protocol::param_value::ParamValue;
use crate::protocol::row_buffer::RowBuffer;
use std::io::Write;
use thiserror::Error;

const MAGIC: u32 = 0x4F444243;
const VERSION: u16 = 1;

/// Appended after the v1 row-major message when a query used `OUT` / `INOUT` parameters.
pub const OUTPUT_FOOTER_MAGIC: [u8; 4] = *b"OUT1";

/// After `OUT1`, optional materialized Oracle / `SYS_REFCURSOR` result sets: `RC1` + NUL
/// padding to 4 bytes (same style as `OUT1`), then `u32` count, then repeated
/// (`u32` len + full v1 `RowBufferEncoder` message per cursor).
pub const REF_CURSOR_FOOTER_MAGIC: [u8; 4] = [b'R', b'C', b'1', 0];

pub struct RowBufferEncoder;

#[derive(Debug, Error)]
pub enum EncodeError {
    #[error("{field} value {value} exceeds {target}")]
    LengthTooLarge {
        field: &'static str,
        value: usize,
        target: &'static str,
    },

    #[error("payload size overflow while adding {context}")]
    PayloadSizeOverflow { context: &'static str },

    #[error("writer error: {0}")]
    Io(#[from] std::io::Error),
}

impl RowBufferEncoder {
    pub fn encode(buffer: &RowBuffer) -> Vec<u8> {
        Self::try_encode(buffer).expect("row buffer exceeds binary protocol limits")
    }

    pub fn try_encode(buffer: &RowBuffer) -> Result<Vec<u8>, EncodeError> {
        let mut output = Vec::new();
        Self::encode_to_writer(buffer, &mut output)?;
        Ok(output)
    }

    /// Encode buffer to a writer. Used for spill-to-disk when result exceeds memory threshold.
    pub fn encode_to_writer<W: Write>(buffer: &RowBuffer, w: &mut W) -> Result<(), EncodeError> {
        let column_count = checked_u16_len(buffer.column_count(), "column count")?;
        let row_count = checked_u32_len(buffer.row_count(), "row count")?;
        let mut metadata_size = 0usize;
        for col in &buffer.columns {
            checked_u16_len(col.name.len(), "column name length")?;
            metadata_size = checked_payload_add(metadata_size, 2, "column type")?;
            metadata_size = checked_payload_add(metadata_size, 2, "column name length")?;
            metadata_size = checked_payload_add(metadata_size, col.name.len(), "column name")?;
        }

        let mut payload_size = metadata_size;
        for row in &buffer.rows {
            for cell in row {
                payload_size = checked_payload_add(payload_size, 1, "cell null flag")?;
                if let Some(data) = cell {
                    checked_u32_len(data.len(), "cell data length")?;
                    payload_size = checked_payload_add(payload_size, 4, "cell data length")?;
                    payload_size = checked_payload_add(payload_size, data.len(), "cell data")?;
                }
            }
        }
        let payload_size = checked_u32_len(payload_size, "payload size")?;

        w.write_all(&MAGIC.to_le_bytes())?;
        w.write_all(&VERSION.to_le_bytes())?;
        w.write_all(&column_count.to_le_bytes())?;
        w.write_all(&row_count.to_le_bytes())?;
        w.write_all(&payload_size.to_le_bytes())?;

        for col in &buffer.columns {
            w.write_all(&(col.odbc_type as u16).to_le_bytes())?;
            let name_len = checked_u16_len(col.name.len(), "column name length")?;
            w.write_all(&name_len.to_le_bytes())?;
            w.write_all(col.name.as_bytes())?;
        }

        for row in &buffer.rows {
            for cell in row {
                if let Some(data) = cell {
                    w.write_all(&[0])?;
                    let data_len = checked_u32_len(data.len(), "cell data length")?;
                    w.write_all(&data_len.to_le_bytes())?;
                    w.write_all(data)?;
                } else {
                    w.write_all(&[1])?;
                }
            }
        }

        Ok(())
    }

    /// Extends a row-major v1 [encode] result with a footer of [ParamValue] (same wire as request params).
    pub fn append_output_footer(base: Vec<u8>, outputs: &[ParamValue]) -> Vec<u8> {
        Self::try_append_output_footer(base, outputs)
            .expect("output footer exceeds binary protocol limits")
    }

    pub fn try_append_output_footer(
        mut base: Vec<u8>,
        outputs: &[ParamValue],
    ) -> Result<Vec<u8>, EncodeError> {
        if outputs.is_empty() {
            return Ok(base);
        }
        base.extend_from_slice(&OUTPUT_FOOTER_MAGIC);
        let output_count = checked_u32_len(outputs.len(), "output parameter count")?;
        base.extend_from_slice(&output_count.to_le_bytes());
        for p in outputs {
            base.extend(p.serialize());
        }
        Ok(base)
    }

    /// Appends one or more full v1 row-major messages (e.g. fetched `SYS_REFCURSOR` sets).
    pub fn append_ref_cursor_footer(base: Vec<u8>, blobs: &[Vec<u8>]) -> Vec<u8> {
        Self::try_append_ref_cursor_footer(base, blobs)
            .expect("ref cursor footer exceeds binary protocol limits")
    }

    pub fn try_append_ref_cursor_footer(
        mut base: Vec<u8>,
        blobs: &[Vec<u8>],
    ) -> Result<Vec<u8>, EncodeError> {
        if blobs.is_empty() {
            return Ok(base);
        }
        base.extend_from_slice(&REF_CURSOR_FOOTER_MAGIC);
        let blob_count = checked_u32_len(blobs.len(), "ref cursor count")?;
        base.extend_from_slice(&blob_count.to_le_bytes());
        for b in blobs {
            let blob_len = checked_u32_len(b.len(), "ref cursor payload length")?;
            base.extend_from_slice(&blob_len.to_le_bytes());
            base.extend_from_slice(b);
        }
        Ok(base)
    }

    /// Encode then optionally compress when payload exceeds 1MB.
    pub fn encode_with_compression(buffer: &RowBuffer) -> Vec<u8> {
        Self::try_encode_with_compression(buffer)
            .expect("row buffer exceeds binary protocol limits")
    }

    pub fn try_encode_with_compression(buffer: &RowBuffer) -> Result<Vec<u8>, EncodeError> {
        let raw = Self::try_encode(buffer)?;
        let strategy = CompressionStrategy::auto_select(raw.len());
        Ok(match strategy.compress_owned(raw) {
            Ok(compressed) => compressed,
            Err(_) => Self::try_encode(buffer)?,
        })
    }
}

fn checked_u16_len(value: usize, field: &'static str) -> Result<u16, EncodeError> {
    value.try_into().map_err(|_| EncodeError::LengthTooLarge {
        field,
        value,
        target: "u16",
    })
}

fn checked_u32_len(value: usize, field: &'static str) -> Result<u32, EncodeError> {
    value.try_into().map_err(|_| EncodeError::LengthTooLarge {
        field,
        value,
        target: "u32",
    })
}

fn checked_payload_add(
    current: usize,
    added: usize,
    context: &'static str,
) -> Result<usize, EncodeError> {
    current
        .checked_add(added)
        .ok_or(EncodeError::PayloadSizeOverflow { context })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::types::OdbcType;

    #[test]
    fn ref_cursor_footer_roundtrip_length() {
        let rb = RowBuffer::new();
        let a = RowBufferEncoder::encode(&rb);
        let a_len = a.len();
        let b = RowBufferEncoder::encode(&rb);
        let c = RowBufferEncoder::append_ref_cursor_footer(a, std::slice::from_ref(&b));
        assert!(c.len() > a_len);
        let count = u32::from_le_bytes([c[a_len + 4], c[a_len + 5], c[a_len + 6], c[a_len + 7]]);
        assert_eq!(count, 1u32);
        let blen =
            u32::from_le_bytes([c[a_len + 8], c[a_len + 9], c[a_len + 10], c[a_len + 11]]) as usize;
        assert_eq!(blen, b.len());
        assert_eq!(&c[a_len + 12..a_len + 12 + blen], &b[..]);
    }

    #[test]
    fn try_encode_rejects_column_count_over_u16() {
        let mut buffer = RowBuffer::new();
        for _ in 0..=u16::MAX {
            buffer.add_column(String::new(), OdbcType::Integer);
        }

        let err = RowBufferEncoder::try_encode(&buffer).unwrap_err();

        assert!(matches!(
            err,
            EncodeError::LengthTooLarge {
                field: "column count",
                target: "u16",
                ..
            }
        ));
    }

    #[test]
    fn try_encode_rejects_column_name_over_u16() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("x".repeat(usize::from(u16::MAX) + 1), OdbcType::Varchar);

        let err = RowBufferEncoder::try_encode(&buffer).unwrap_err();

        assert!(matches!(
            err,
            EncodeError::LengthTooLarge {
                field: "column name length",
                target: "u16",
                ..
            }
        ));
    }

    #[test]
    fn checked_u32_len_rejects_cell_size_overflow() {
        let err = checked_u32_len(usize::MAX, "cell data length").unwrap_err();

        assert!(matches!(
            err,
            EncodeError::LengthTooLarge {
                field: "cell data length",
                target: "u32",
                ..
            }
        ));
    }

    #[test]
    fn checked_payload_add_rejects_size_overflow() {
        let err = checked_payload_add(usize::MAX, 1, "cell data").unwrap_err();

        assert!(matches!(
            err,
            EncodeError::PayloadSizeOverflow {
                context: "cell data"
            }
        ));
    }

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

        // Verify payload size
        let payload_size = u32::from_le_bytes([encoded[12], encoded[13], encoded[14], encoded[15]]);
        assert_eq!(payload_size, 0);
    }

    #[test]
    fn test_encode_single_column_no_rows() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("id".to_string(), OdbcType::Integer);

        let encoded = RowBufferEncoder::encode(&buffer);

        // Header(16) + column_metadata(2 + 2 + 2) = 22 bytes
        assert_eq!(encoded.len(), 22);
        let payload_size = u32::from_le_bytes([encoded[12], encoded[13], encoded[14], encoded[15]]);
        assert_eq!(payload_size, 6);

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
    fn test_encode_to_writer_matches_encode() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("id".to_string(), OdbcType::Integer);
        buffer.add_row(vec![Some(vec![1, 0, 0, 0])]);
        buffer.add_row(vec![Some(vec![2, 0, 0, 0])]);

        let encoded = RowBufferEncoder::encode(&buffer);
        let mut out = Vec::new();
        RowBufferEncoder::encode_to_writer(&buffer, &mut out).unwrap();
        assert_eq!(encoded, out);
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

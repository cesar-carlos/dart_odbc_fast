use crate::error::{OdbcError, Result};
use crate::protocol::types::OdbcType;

pub(crate) const MAGIC: u32 = 0x4F444243;
pub(crate) const VERSION: u16 = 1;
const HEADER_SIZE: usize = 16; // magic(4) + version(2) + col_count(2) + row_count(4) + payload_size(4)
pub(crate) const MAX_DECODED_COLUMNS: usize = 4096;
pub(crate) const MAX_DECODED_ROWS: usize = 1_000_000;
pub(crate) const MAX_DECODED_CELLS: usize = 5_000_000;
pub(crate) const MAX_DECODED_PAYLOAD_SIZE: usize = 256 * 1024 * 1024;
pub(crate) const MAX_DECODED_CELL_SIZE: usize = 64 * 1024 * 1024;

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
            let name = std::str::from_utf8(&buffer[offset..offset + name_len])
                .map_err(|e| {
                    OdbcError::ValidationError(format!("Invalid UTF-8 in column name: {}", e))
                })?
                .to_owned();
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
mod tests;

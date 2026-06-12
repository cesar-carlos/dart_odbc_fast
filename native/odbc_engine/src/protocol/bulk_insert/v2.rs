use crate::error::{OdbcError, Result};

use super::common::{
    len_to_u32, read_bytes, read_null_bitmap, read_u16_le, read_u32_le, validate_variable_cell_len,
    write_null_bitmap, BulkColumnData, BulkColumnSpec, BulkColumnType, BulkInsertPayload,
    BULK_V2_FLAGS_NONE, BULK_V2_MAGIC, BULK_V2_VERSION,
};
use super::legacy::{parse_column_data, serialize_column_data};

pub(crate) fn parse_bulk_insert_payload_v2(data: &[u8]) -> Result<BulkInsertPayload> {
    let mut o = BULK_V2_MAGIC.len();
    let version = read_u16_le(data, &mut o)?;
    if version != BULK_V2_VERSION {
        return Err(OdbcError::ValidationError(format!(
            "Unsupported bulk insert payload version: {version}"
        )));
    }
    let flags = read_u16_le(data, &mut o)?;
    if flags != BULK_V2_FLAGS_NONE {
        return Err(OdbcError::ValidationError(format!(
            "Unsupported bulk insert payload flags: {flags}"
        )));
    }
    super::parse_bulk_insert_payload_body(data, &mut o, super::common::BulkPayloadWire::V2)
}

pub(crate) fn parse_column_data_v2(
    data: &[u8],
    start: usize,
    spec: &BulkColumnSpec,
    row_count: usize,
) -> Result<(BulkColumnData, usize)> {
    let mut o = start;

    match &spec.col_type {
        BulkColumnType::Text | BulkColumnType::Decimal => {
            let null_bitmap = read_null_bitmap(data, &mut o, spec.nullable, row_count)?;
            let mut rows = Vec::with_capacity(row_count);
            for _ in 0..row_count {
                let len = read_u32_le(data, &mut o)? as usize;
                validate_variable_cell_len(len, spec.max_len)?;
                rows.push(read_bytes(data, &mut o, len)?.to_vec());
            }
            Ok((
                BulkColumnData::Text {
                    rows,
                    max_len: spec.max_len,
                    null_bitmap,
                },
                o - start,
            ))
        }
        BulkColumnType::Binary => {
            let null_bitmap = read_null_bitmap(data, &mut o, spec.nullable, row_count)?;
            let mut rows = Vec::with_capacity(row_count);
            for _ in 0..row_count {
                let len = read_u32_le(data, &mut o)? as usize;
                validate_variable_cell_len(len, spec.max_len)?;
                rows.push(read_bytes(data, &mut o, len)?.to_vec());
            }
            Ok((
                BulkColumnData::Binary {
                    rows,
                    max_len: spec.max_len,
                    null_bitmap,
                },
                o - start,
            ))
        }
        _ => parse_column_data(data, start, spec, row_count),
    }
}

pub(crate) fn serialize_column_data_v2(
    out: &mut Vec<u8>,
    spec: &BulkColumnSpec,
    data: &BulkColumnData,
    row_count: usize,
) -> Result<()> {
    match (data, &spec.col_type) {
        (
            BulkColumnData::Text {
                rows, null_bitmap, ..
            },
            BulkColumnType::Text,
        )
        | (
            BulkColumnData::Text {
                rows, null_bitmap, ..
            },
            BulkColumnType::Decimal,
        ) => {
            write_null_bitmap(out, null_bitmap);
            write_variable_rows_v2(out, rows, spec.max_len, row_count)
        }
        (
            BulkColumnData::Binary {
                rows, null_bitmap, ..
            },
            BulkColumnType::Binary,
        ) => {
            write_null_bitmap(out, null_bitmap);
            write_variable_rows_v2(out, rows, spec.max_len, row_count)
        }
        _ => serialize_column_data(out, spec, data, row_count),
    }
}

pub(crate) fn write_variable_rows_v2(
    out: &mut Vec<u8>,
    rows: &[Vec<u8>],
    max_len: usize,
    row_count: usize,
) -> Result<()> {
    if rows.len() != row_count {
        return Err(OdbcError::MalformedPayload(format!(
            "row count mismatch: expected {row_count}, got {}",
            rows.len()
        )));
    }
    for row in rows {
        validate_variable_cell_len(row.len(), max_len)?;
        out.extend_from_slice(&len_to_u32(row.len(), "cell length")?.to_le_bytes());
        out.extend_from_slice(row);
    }
    Ok(())
}

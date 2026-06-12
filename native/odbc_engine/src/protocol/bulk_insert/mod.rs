mod common;
mod legacy;
mod v2;

#[cfg(test)]
mod tests;

pub use common::{
    bulk_rows_from_vecs, is_null, is_null_strict, null_bitmap_size, BulkCellBytes, BulkColumnData,
    BulkColumnSpec, BulkColumnType, BulkInsertPayload, BulkTimestamp, MAX_BULK_CELL_LEN,
    MAX_BULK_COLUMNS, MAX_BULK_ROWS,
};

use crate::error::{OdbcError, Result};
use common::{
    checked_payload_size_add, checked_payload_size_mul, len_to_u32, read_bytes, read_u32_le,
    BulkPayloadWire, BULK_V2_FLAGS_NONE, BULK_V2_MAGIC, BULK_V2_VERSION,
};
use std::str;
use std::sync::Arc;

pub fn parse_bulk_insert_payload(data: &[u8]) -> Result<BulkInsertPayload> {
    if data.starts_with(BULK_V2_MAGIC) {
        v2::parse_bulk_insert_payload_v2(data)
    } else {
        parse_bulk_insert_payload_legacy(data)
    }
}

fn parse_bulk_insert_payload_legacy(data: &[u8]) -> Result<BulkInsertPayload> {
    let mut o = 0usize;
    parse_bulk_insert_payload_body(data, &mut o, BulkPayloadWire::Legacy)
}

pub(super) fn parse_bulk_insert_payload_body(
    data: &[u8],
    o: &mut usize,
    wire: BulkPayloadWire,
) -> Result<BulkInsertPayload> {
    let wire_backing: Arc<[u8]> = Arc::from(data.to_vec());
    let data = wire_backing.as_ref();
    let table_len = read_u32_le(data, o)? as usize;
    let table_bytes = read_bytes(data, o, table_len)?;
    let table = str::from_utf8(table_bytes).map_err(|_| {
        OdbcError::ValidationError("Bulk insert table name invalid UTF-8".to_string())
    })?;
    let table = table.to_string();

    let col_count = read_u32_le(data, o)? as usize;
    if col_count > MAX_BULK_COLUMNS {
        return Err(OdbcError::ResourceLimitReached(format!(
            "column count {col_count} exceeds MAX_BULK_COLUMNS={MAX_BULK_COLUMNS}"
        )));
    }
    let mut columns = Vec::with_capacity(col_count);
    for _ in 0..col_count {
        let name_len = read_u32_le(data, o)? as usize;
        let name_bytes = read_bytes(data, o, name_len)?;
        let name = str::from_utf8(name_bytes).map_err(|_| {
            OdbcError::ValidationError("Bulk insert column name invalid UTF-8".to_string())
        })?;
        let name = name.to_string();
        if data.len() <= *o {
            return Err(OdbcError::ValidationError(
                "Bulk insert payload truncated (column spec)".to_string(),
            ));
        }
        let type_tag = data[*o];
        *o += 1;
        let nullable = if data.len() <= *o {
            return Err(OdbcError::ValidationError(
                "Bulk insert payload truncated (nullable)".to_string(),
            ));
        } else {
            data[*o] != 0
        };
        *o += 1;
        let max_len = read_u32_le(data, o)? as usize;
        if max_len > MAX_BULK_CELL_LEN {
            return Err(OdbcError::ResourceLimitReached(format!(
                "max_len {max_len} exceeds MAX_BULK_CELL_LEN={MAX_BULK_CELL_LEN}"
            )));
        }
        let col_type = BulkColumnType::from_tag(type_tag)?;
        columns.push(BulkColumnSpec {
            name,
            col_type,
            nullable,
            max_len,
        });
    }

    let row_count = read_u32_le(data, o)? as usize;
    if row_count > MAX_BULK_ROWS {
        return Err(OdbcError::ResourceLimitReached(format!(
            "row count {row_count} exceeds MAX_BULK_ROWS={MAX_BULK_ROWS}"
        )));
    }

    let mut column_data = Vec::with_capacity(columns.len());
    for spec in &columns {
        let (data_col, consumed) = match wire {
            BulkPayloadWire::Legacy => {
                legacy::parse_column_data(data, *o, spec, row_count, &wire_backing)?
            }
            BulkPayloadWire::V2 => {
                v2::parse_column_data_v2(data, *o, spec, row_count, &wire_backing)?
            }
        };
        column_data.push(data_col);
        *o += consumed;
    }

    if *o != data.len() {
        return Err(OdbcError::ValidationError(
            "Bulk insert payload length mismatch".to_string(),
        ));
    }

    Ok(BulkInsertPayload {
        table,
        columns,
        row_count: row_count as u32,
        column_data,
    })
}

pub fn serialize_bulk_insert_payload(payload: &BulkInsertPayload) -> Result<Vec<u8>> {
    serialize_bulk_insert_payload_with_wire(payload, BulkPayloadWire::Legacy)
}

pub fn serialize_bulk_insert_payload_v2(payload: &BulkInsertPayload) -> Result<Vec<u8>> {
    serialize_bulk_insert_payload_with_wire(payload, BulkPayloadWire::V2)
}

fn serialize_bulk_insert_payload_with_wire(
    payload: &BulkInsertPayload,
    wire: BulkPayloadWire,
) -> Result<Vec<u8>> {
    if payload.columns.len() > MAX_BULK_COLUMNS {
        return Err(OdbcError::ResourceLimitReached(format!(
            "column count {} exceeds MAX_BULK_COLUMNS={MAX_BULK_COLUMNS}",
            payload.columns.len()
        )));
    }
    if payload.row_count as usize > MAX_BULK_ROWS {
        return Err(OdbcError::ResourceLimitReached(format!(
            "row count {} exceeds MAX_BULK_ROWS={MAX_BULK_ROWS}",
            payload.row_count
        )));
    }
    let mut out = Vec::with_capacity(estimate_serialized_payload_size(payload, wire)?);
    if wire == BulkPayloadWire::V2 {
        out.extend_from_slice(BULK_V2_MAGIC);
        out.extend_from_slice(&BULK_V2_VERSION.to_le_bytes());
        out.extend_from_slice(&BULK_V2_FLAGS_NONE.to_le_bytes());
    }
    let table_b = payload.table.as_bytes();
    out.extend_from_slice(&len_to_u32(table_b.len(), "table name")?.to_le_bytes());
    out.extend_from_slice(table_b);
    out.extend_from_slice(&len_to_u32(payload.columns.len(), "column count")?.to_le_bytes());

    for spec in &payload.columns {
        let name_b = spec.name.as_bytes();
        out.extend_from_slice(&len_to_u32(name_b.len(), "column name")?.to_le_bytes());
        out.extend_from_slice(name_b);
        out.push(spec.col_type.to_tag());
        out.push(if spec.nullable { 1 } else { 0 });
        if spec.max_len > MAX_BULK_CELL_LEN {
            return Err(OdbcError::ResourceLimitReached(format!(
                "max_len {} exceeds MAX_BULK_CELL_LEN={MAX_BULK_CELL_LEN}",
                spec.max_len
            )));
        }
        out.extend_from_slice(&len_to_u32(spec.max_len, "max_len")?.to_le_bytes());
    }

    out.extend_from_slice(&payload.row_count.to_le_bytes());

    for (spec, data) in payload.columns.iter().zip(payload.column_data.iter()) {
        match wire {
            BulkPayloadWire::Legacy => {
                legacy::serialize_column_data(&mut out, spec, data, payload.row_count as usize)?
            }
            BulkPayloadWire::V2 => {
                v2::serialize_column_data_v2(&mut out, spec, data, payload.row_count as usize)?
            }
        }
    }

    Ok(out)
}

pub(crate) fn estimate_serialized_payload_size(
    payload: &BulkInsertPayload,
    wire: BulkPayloadWire,
) -> Result<usize> {
    let mut size = 0usize;
    if wire == BulkPayloadWire::V2 {
        size = checked_payload_size_add(size, BULK_V2_MAGIC.len())?;
        size = checked_payload_size_add(size, 2)?; // version
        size = checked_payload_size_add(size, 2)?; // flags
    }

    size = checked_payload_size_add(size, 4)?; // table length
    size = checked_payload_size_add(size, payload.table.len())?;
    size = checked_payload_size_add(size, 4)?; // column count

    for spec in &payload.columns {
        size = checked_payload_size_add(size, 4)?; // column name length
        size = checked_payload_size_add(size, spec.name.len())?;
        size = checked_payload_size_add(size, 1)?; // type tag
        size = checked_payload_size_add(size, 1)?; // nullable
        size = checked_payload_size_add(size, 4)?; // max_len
    }

    size = checked_payload_size_add(size, 4)?; // row count

    let row_count = payload.row_count as usize;
    for (spec, data) in payload.columns.iter().zip(payload.column_data.iter()) {
        if spec.nullable {
            size = checked_payload_size_add(size, null_bitmap_size(row_count))?;
        }
        size = checked_payload_size_add(
            size,
            match (wire, data, &spec.col_type) {
                (_, BulkColumnData::I32 { values, .. }, BulkColumnType::I32) => {
                    checked_payload_size_mul(values.len(), 4)?
                }
                (_, BulkColumnData::I64 { values, .. }, BulkColumnType::I64) => {
                    checked_payload_size_mul(values.len(), 8)?
                }
                (_, BulkColumnData::Timestamp { values, .. }, BulkColumnType::Timestamp) => {
                    checked_payload_size_mul(values.len(), 16)?
                }
                (BulkPayloadWire::Legacy, BulkColumnData::Text { rows, max_len, .. }, _)
                | (BulkPayloadWire::Legacy, BulkColumnData::Binary { rows, max_len, .. }, _) => {
                    checked_payload_size_mul(rows.len(), *max_len)?
                }
                (BulkPayloadWire::V2, BulkColumnData::Text { rows, .. }, _)
                | (BulkPayloadWire::V2, BulkColumnData::Binary { rows, .. }, _) => {
                    rows.iter().try_fold(0usize, |acc, row| {
                        checked_payload_size_add(acc, 4)
                            .and_then(|acc| checked_payload_size_add(acc, row.as_slice().len()))
                    })?
                }
                _ => 0,
            },
        )?;
    }

    Ok(size)
}

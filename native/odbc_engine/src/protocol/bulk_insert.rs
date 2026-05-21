use crate::error::{OdbcError, Result};
use std::str;

/// Hard cap on column count to bound memory in `parse_bulk_insert_payload`.
/// Chosen to comfortably exceed any real-world table while preventing
/// allocation-bomb attacks via crafted payloads.
pub const MAX_BULK_COLUMNS: usize = 4096;

/// Hard cap on row count per single bulk-insert payload.
pub const MAX_BULK_ROWS: usize = 10_000_000;

/// Hard cap on per-cell `max_len` (bytes). 16 MiB is well above realistic
/// VARCHAR/VARBINARY widths.
pub const MAX_BULK_CELL_LEN: usize = 16 * 1024 * 1024;

const BULK_V2_MAGIC: &[u8; 4] = b"BLK2";
const BULK_V2_VERSION: u16 = 2;
const BULK_V2_FLAGS_NONE: u16 = 0;

const TAG_I32: u8 = 0;
const TAG_I64: u8 = 1;
const TAG_TEXT: u8 = 2;
const TAG_DECIMAL: u8 = 3;
const TAG_BINARY: u8 = 4;
const TAG_TIMESTAMP: u8 = 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BulkColumnType {
    I32,
    I64,
    Text,
    Decimal,
    Binary,
    Timestamp,
}

impl BulkColumnType {
    fn from_tag(tag: u8) -> Result<Self> {
        match tag {
            TAG_I32 => Ok(BulkColumnType::I32),
            TAG_I64 => Ok(BulkColumnType::I64),
            TAG_TEXT => Ok(BulkColumnType::Text),
            TAG_DECIMAL => Ok(BulkColumnType::Decimal),
            TAG_BINARY => Ok(BulkColumnType::Binary),
            TAG_TIMESTAMP => Ok(BulkColumnType::Timestamp),
            _ => Err(OdbcError::ValidationError(format!(
                "Unknown bulk column type tag: {}",
                tag
            ))),
        }
    }

    fn to_tag(&self) -> u8 {
        match self {
            BulkColumnType::I32 => TAG_I32,
            BulkColumnType::I64 => TAG_I64,
            BulkColumnType::Text => TAG_TEXT,
            BulkColumnType::Decimal => TAG_DECIMAL,
            BulkColumnType::Binary => TAG_BINARY,
            BulkColumnType::Timestamp => TAG_TIMESTAMP,
        }
    }
}

#[derive(Debug, Clone)]
pub struct BulkColumnSpec {
    pub name: String,
    pub col_type: BulkColumnType,
    pub nullable: bool,
    pub max_len: usize,
}

#[derive(Debug, Clone)]
pub struct BulkInsertPayload {
    pub table: String,
    pub columns: Vec<BulkColumnSpec>,
    pub row_count: u32,
    pub column_data: Vec<BulkColumnData>,
}

#[derive(Debug, Clone)]
pub enum BulkColumnData {
    I32 {
        values: Vec<i32>,
        null_bitmap: Option<Vec<u8>>,
    },
    I64 {
        values: Vec<i64>,
        null_bitmap: Option<Vec<u8>>,
    },
    Text {
        rows: Vec<Vec<u8>>,
        max_len: usize,
        null_bitmap: Option<Vec<u8>>,
    },
    Binary {
        rows: Vec<Vec<u8>>,
        max_len: usize,
        null_bitmap: Option<Vec<u8>>,
    },
    Timestamp {
        values: Vec<BulkTimestamp>,
        null_bitmap: Option<Vec<u8>>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BulkTimestamp {
    pub year: i16,
    pub month: u16,
    pub day: u16,
    pub hour: u16,
    pub minute: u16,
    pub second: u16,
    pub fraction: u32,
}

fn read_u32_le(data: &[u8], offset: &mut usize) -> Result<u32> {
    if data.len().saturating_sub(*offset) < 4 {
        return Err(OdbcError::ValidationError(
            "Bulk insert payload truncated (u32)".to_string(),
        ));
    }
    let v = u32::from_le_bytes([
        data[*offset],
        data[*offset + 1],
        data[*offset + 2],
        data[*offset + 3],
    ]);
    *offset += 4;
    Ok(v)
}

fn read_u16_le(data: &[u8], offset: &mut usize) -> Result<u16> {
    if data.len().saturating_sub(*offset) < 2 {
        return Err(OdbcError::ValidationError(
            "Bulk insert payload truncated (u16)".to_string(),
        ));
    }
    let v = u16::from_le_bytes([data[*offset], data[*offset + 1]]);
    *offset += 2;
    Ok(v)
}

fn read_bytes<'a>(data: &'a [u8], offset: &mut usize, len: usize) -> Result<&'a [u8]> {
    if data.len().saturating_sub(*offset) < len {
        return Err(OdbcError::ValidationError(
            "Bulk insert payload truncated (bytes)".to_string(),
        ));
    }
    let slice = &data[*offset..*offset + len];
    *offset += len;
    Ok(slice)
}

pub fn null_bitmap_size(n: usize) -> usize {
    n.div_ceil(8)
}

/// Read the null bit for `row` from a packed bitmap.
///
/// Returns `false` when `row` is beyond the bitmap (treated as "not null") to
/// preserve historical behaviour. **The single source of truth for bitmap
/// integrity is `parse_bulk_insert_payload`**, which rejects payloads whose
/// bitmap length differs from `null_bitmap_size(row_count)` (C9).
pub fn is_null(bitmap: &[u8], row: usize) -> bool {
    if row / 8 >= bitmap.len() {
        return false;
    }
    (bitmap[row / 8] & (1u8 << (row % 8))) != 0
}

/// Strict bitmap accessor: returns an error when the bit lies outside the
/// bitmap, instead of defaulting to `false`. Use in code paths that have
/// already been promoted to validate payloads up-front.
pub fn is_null_strict(bitmap: &[u8], row: usize, row_count: usize) -> Result<bool> {
    if row >= row_count {
        return Err(OdbcError::MalformedPayload(format!(
            "row index {row} out of range (row_count={row_count})"
        )));
    }
    let byte_idx = row / 8;
    if byte_idx >= bitmap.len() {
        return Err(OdbcError::MalformedPayload(format!(
            "null bitmap truncated: byte index {byte_idx} out of range (len={})",
            bitmap.len()
        )));
    }
    Ok((bitmap[byte_idx] & (1u8 << (row % 8))) != 0)
}

pub fn parse_bulk_insert_payload(data: &[u8]) -> Result<BulkInsertPayload> {
    if data.starts_with(BULK_V2_MAGIC) {
        parse_bulk_insert_payload_v2(data)
    } else {
        parse_bulk_insert_payload_legacy(data)
    }
}

fn parse_bulk_insert_payload_legacy(data: &[u8]) -> Result<BulkInsertPayload> {
    let mut o = 0usize;
    parse_bulk_insert_payload_body(data, &mut o, BulkPayloadWire::Legacy)
}

fn parse_bulk_insert_payload_v2(data: &[u8]) -> Result<BulkInsertPayload> {
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
    parse_bulk_insert_payload_body(data, &mut o, BulkPayloadWire::V2)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BulkPayloadWire {
    Legacy,
    V2,
}

fn parse_bulk_insert_payload_body(
    data: &[u8],
    o: &mut usize,
    wire: BulkPayloadWire,
) -> Result<BulkInsertPayload> {
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
            BulkPayloadWire::Legacy => parse_column_data(data, *o, spec, row_count)?,
            BulkPayloadWire::V2 => parse_column_data_v2(data, *o, spec, row_count)?,
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

/// Read a null-bitmap of exactly `null_bitmap_size(row_count)` bytes and verify it.
fn read_null_bitmap(
    data: &[u8],
    o: &mut usize,
    nullable: bool,
    row_count: usize,
) -> Result<Option<Vec<u8>>> {
    if !nullable {
        return Ok(None);
    }
    let expected = null_bitmap_size(row_count);
    let bytes = read_bytes(data, o, expected)?.to_vec();
    if bytes.len() != expected {
        return Err(OdbcError::MalformedPayload(format!(
            "null bitmap length mismatch: expected {expected}, got {}",
            bytes.len()
        )));
    }
    Ok(Some(bytes))
}

fn parse_column_data(
    data: &[u8],
    start: usize,
    spec: &BulkColumnSpec,
    row_count: usize,
) -> Result<(BulkColumnData, usize)> {
    let mut o = start;

    match &spec.col_type {
        BulkColumnType::I32 => {
            let null_bitmap = read_null_bitmap(data, &mut o, spec.nullable, row_count)?;
            let mut values = Vec::with_capacity(row_count);
            for _ in 0..row_count {
                let v = read_u32_le(data, &mut o)? as i32;
                values.push(v);
            }
            let consumed = o - start;
            Ok((
                BulkColumnData::I32 {
                    values,
                    null_bitmap,
                },
                consumed,
            ))
        }
        BulkColumnType::I64 => {
            let null_bitmap = read_null_bitmap(data, &mut o, spec.nullable, row_count)?;
            let mut values = Vec::with_capacity(row_count);
            for _ in 0..row_count {
                if data.len().saturating_sub(o) < 8 {
                    return Err(OdbcError::ValidationError(
                        "Bulk insert payload truncated (i64)".to_string(),
                    ));
                }
                let v = i64::from_le_bytes([
                    data[o],
                    data[o + 1],
                    data[o + 2],
                    data[o + 3],
                    data[o + 4],
                    data[o + 5],
                    data[o + 6],
                    data[o + 7],
                ]);
                o += 8;
                values.push(v);
            }
            Ok((
                BulkColumnData::I64 {
                    values,
                    null_bitmap,
                },
                o - start,
            ))
        }
        BulkColumnType::Text | BulkColumnType::Decimal => {
            let null_bitmap = read_null_bitmap(data, &mut o, spec.nullable, row_count)?;
            let max_len = spec.max_len.max(1);
            let mut rows = Vec::with_capacity(row_count);
            for _ in 0..row_count {
                let raw = read_bytes(data, &mut o, max_len)?;
                rows.push(trim_legacy_nul_padded_cell(raw).to_vec());
            }
            Ok((
                BulkColumnData::Text {
                    rows,
                    max_len,
                    null_bitmap,
                },
                o - start,
            ))
        }
        BulkColumnType::Binary => {
            let null_bitmap = read_null_bitmap(data, &mut o, spec.nullable, row_count)?;
            let max_len = spec.max_len.max(1);
            let mut rows = Vec::with_capacity(row_count);
            for _ in 0..row_count {
                let raw = read_bytes(data, &mut o, max_len)?;
                rows.push(trim_legacy_nul_padded_cell(raw).to_vec());
            }
            Ok((
                BulkColumnData::Binary {
                    rows,
                    max_len,
                    null_bitmap,
                },
                o - start,
            ))
        }
        BulkColumnType::Timestamp => {
            let null_bitmap = read_null_bitmap(data, &mut o, spec.nullable, row_count)?;
            let mut values = Vec::with_capacity(row_count);
            for _ in 0..row_count {
                if data.len().saturating_sub(o) < 16 {
                    return Err(OdbcError::ValidationError(
                        "Bulk insert payload truncated (timestamp)".to_string(),
                    ));
                }
                let year = i16::from_le_bytes([data[o], data[o + 1]]);
                let month = u16::from_le_bytes([data[o + 2], data[o + 3]]);
                let day = u16::from_le_bytes([data[o + 4], data[o + 5]]);
                let hour = u16::from_le_bytes([data[o + 6], data[o + 7]]);
                let minute = u16::from_le_bytes([data[o + 8], data[o + 9]]);
                let second = u16::from_le_bytes([data[o + 10], data[o + 11]]);
                let fraction =
                    u32::from_le_bytes([data[o + 12], data[o + 13], data[o + 14], data[o + 15]]);
                o += 16;
                values.push(BulkTimestamp {
                    year,
                    month,
                    day,
                    hour,
                    minute,
                    second,
                    fraction,
                });
            }
            Ok((
                BulkColumnData::Timestamp {
                    values,
                    null_bitmap,
                },
                o - start,
            ))
        }
    }
}

fn trim_legacy_nul_padded_cell(raw: &[u8]) -> &[u8] {
    let end = raw.iter().position(|&b| b == 0).unwrap_or(raw.len());
    &raw[..end]
}

fn parse_column_data_v2(
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

fn validate_variable_cell_len(len: usize, max_len: usize) -> Result<()> {
    if len > MAX_BULK_CELL_LEN {
        return Err(OdbcError::ResourceLimitReached(format!(
            "cell length {len} exceeds MAX_BULK_CELL_LEN={MAX_BULK_CELL_LEN}"
        )));
    }
    if max_len > 0 && len > max_len {
        return Err(OdbcError::MalformedPayload(format!(
            "cell length {len} exceeds column max_len {max_len}"
        )));
    }
    Ok(())
}

/// Convert `usize` to `u32` for wire-format length fields, returning a
/// validation error instead of silently truncating.
fn len_to_u32(n: usize, what: &str) -> Result<u32> {
    u32::try_from(n).map_err(|_| {
        OdbcError::MalformedPayload(format!(
            "{what} length {n} does not fit in u32 (max {})",
            u32::MAX
        ))
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
                serialize_column_data(&mut out, spec, data, payload.row_count as usize)?
            }
            BulkPayloadWire::V2 => {
                serialize_column_data_v2(&mut out, spec, data, payload.row_count as usize)?
            }
        }
    }

    Ok(out)
}

fn estimate_serialized_payload_size(
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
                            .and_then(|acc| checked_payload_size_add(acc, row.len()))
                    })?
                }
                _ => 0,
            },
        )?;
    }

    Ok(size)
}

fn checked_payload_size_add(current: usize, added: usize) -> Result<usize> {
    current
        .checked_add(added)
        .ok_or_else(|| OdbcError::ResourceLimitReached("bulk payload size overflow".to_string()))
}

fn checked_payload_size_mul(left: usize, right: usize) -> Result<usize> {
    left.checked_mul(right)
        .ok_or_else(|| OdbcError::ResourceLimitReached("bulk payload size overflow".to_string()))
}

fn serialize_column_data(
    out: &mut Vec<u8>,
    spec: &BulkColumnSpec,
    data: &BulkColumnData,
    _row_count: usize,
) -> Result<()> {
    match (data, &spec.col_type) {
        (
            BulkColumnData::I32 {
                values,
                null_bitmap,
            },
            BulkColumnType::I32,
        ) => {
            if let Some(bm) = null_bitmap {
                out.extend_from_slice(bm);
            }
            for &v in values {
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
        (
            BulkColumnData::I64 {
                values,
                null_bitmap,
            },
            BulkColumnType::I64,
        ) => {
            if let Some(bm) = null_bitmap {
                out.extend_from_slice(bm);
            }
            for &v in values {
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
        (
            BulkColumnData::Text {
                rows,
                max_len,
                null_bitmap,
            },
            BulkColumnType::Text,
        )
        | (
            BulkColumnData::Text {
                rows,
                max_len,
                null_bitmap,
            },
            BulkColumnType::Decimal,
        ) => {
            if let Some(bm) = null_bitmap {
                out.extend_from_slice(bm);
            }
            for row in rows {
                let len = row.len().min(*max_len);
                out.extend_from_slice(&row[..len]);
                for _ in len..*max_len {
                    out.push(0);
                }
            }
        }
        (
            BulkColumnData::Binary {
                rows,
                max_len,
                null_bitmap,
            },
            BulkColumnType::Binary,
        ) => {
            if let Some(bm) = null_bitmap {
                out.extend_from_slice(bm);
            }
            for row in rows {
                let len = row.len().min(*max_len);
                out.extend_from_slice(&row[..len]);
                for _ in len..*max_len {
                    out.push(0);
                }
            }
        }
        (
            BulkColumnData::Timestamp {
                values,
                null_bitmap,
            },
            BulkColumnType::Timestamp,
        ) => {
            if let Some(bm) = null_bitmap {
                out.extend_from_slice(bm);
            }
            for t in values {
                out.extend_from_slice(&t.year.to_le_bytes());
                out.extend_from_slice(&t.month.to_le_bytes());
                out.extend_from_slice(&t.day.to_le_bytes());
                out.extend_from_slice(&t.hour.to_le_bytes());
                out.extend_from_slice(&t.minute.to_le_bytes());
                out.extend_from_slice(&t.second.to_le_bytes());
                out.extend_from_slice(&t.fraction.to_le_bytes());
            }
        }
        _ => {
            return Err(OdbcError::ValidationError(
                "Bulk column data does not match spec".to_string(),
            ));
        }
    }
    Ok(())
}

fn serialize_column_data_v2(
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

fn write_null_bitmap(out: &mut Vec<u8>, null_bitmap: &Option<Vec<u8>>) {
    if let Some(bm) = null_bitmap {
        out.extend_from_slice(bm);
    }
}

fn write_variable_rows_v2(
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bulk_insert_parse_roundtrip_i32() {
        let payload = BulkInsertPayload {
            table: "t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "a".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            }],
            row_count: 2,
            column_data: vec![BulkColumnData::I32 {
                values: vec![1, 2],
                null_bitmap: None,
            }],
        };
        let enc = serialize_bulk_insert_payload(&payload).unwrap();
        let dec = parse_bulk_insert_payload(&enc).unwrap();
        assert_eq!(dec.table, "t");
        assert_eq!(dec.columns.len(), 1);
        assert_eq!(dec.columns[0].name, "a");
        assert!(!dec.columns[0].nullable);
        assert_eq!(dec.row_count, 2);
        match &dec.column_data[0] {
            BulkColumnData::I32 {
                values,
                null_bitmap,
            } => {
                assert_eq!(values.as_slice(), &[1, 2]);
                assert!(null_bitmap.is_none());
            }
            _ => panic!("expected I32"),
        }
    }

    #[test]
    fn test_bulk_insert_parse_roundtrip_i32_nullable() {
        let payload = BulkInsertPayload {
            table: "t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "a".to_string(),
                col_type: BulkColumnType::I32,
                nullable: true,
                max_len: 0,
            }],
            row_count: 3,
            column_data: vec![BulkColumnData::I32 {
                values: vec![1, 0, 3],
                null_bitmap: Some(vec![0b010]),
            }],
        };
        let enc = serialize_bulk_insert_payload(&payload).unwrap();
        let dec = parse_bulk_insert_payload(&enc).unwrap();
        assert_eq!(dec.row_count, 3);
        match &dec.column_data[0] {
            BulkColumnData::I32 {
                values,
                null_bitmap,
            } => {
                assert_eq!(values.as_slice(), &[1, 0, 3]);
                assert_eq!(null_bitmap.as_deref(), Some(&[0b010][..]));
            }
            _ => panic!("expected I32"),
        }
    }

    #[test]
    fn test_bulk_insert_parse_roundtrip_text() {
        let payload = BulkInsertPayload {
            table: "t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "x".to_string(),
                col_type: BulkColumnType::Text,
                nullable: false,
                max_len: 10,
            }],
            row_count: 2,
            column_data: vec![BulkColumnData::Text {
                rows: vec![b"hi".to_vec(), b"world".to_vec()],
                max_len: 10,
                null_bitmap: None,
            }],
        };
        let enc = serialize_bulk_insert_payload(&payload).unwrap();
        let dec = parse_bulk_insert_payload(&enc).unwrap();
        assert_eq!(dec.table, "t");
        match &dec.column_data[0] {
            BulkColumnData::Text { rows, max_len, .. } => {
                assert_eq!(*max_len, 10);
                assert_eq!(rows[0], b"hi");
                assert_eq!(rows[1], b"world");
            }
            _ => panic!("expected Text"),
        }
    }

    #[test]
    fn legacy_parse_trims_nul_padding_before_copying_cell() {
        assert_eq!(trim_legacy_nul_padded_cell(b"abc\0\0"), b"abc");
        assert_eq!(trim_legacy_nul_padded_cell(b"abc"), b"abc");
        assert_eq!(trim_legacy_nul_padded_cell(b"\0abc"), b"");
    }

    #[test]
    fn estimate_serialized_payload_size_matches_v2_length() {
        let payload = BulkInsertPayload {
            table: "files".to_string(),
            columns: vec![BulkColumnSpec {
                name: "payload".to_string(),
                col_type: BulkColumnType::Binary,
                nullable: false,
                max_len: 0,
            }],
            row_count: 2,
            column_data: vec![BulkColumnData::Binary {
                rows: vec![vec![1, 0, 2], vec![3, 4]],
                max_len: 0,
                null_bitmap: None,
            }],
        };

        let estimated =
            estimate_serialized_payload_size(&payload, BulkPayloadWire::V2).expect("estimate");
        let encoded = serialize_bulk_insert_payload_v2(&payload).expect("serialize");

        assert_eq!(estimated, encoded.len());
    }

    #[test]
    fn parse_v2_preserves_binary_nul_bytes() {
        let payload = BulkInsertPayload {
            table: "files".to_string(),
            columns: vec![BulkColumnSpec {
                name: "payload".to_string(),
                col_type: BulkColumnType::Binary,
                nullable: false,
                max_len: 8,
            }],
            row_count: 1,
            column_data: vec![BulkColumnData::Binary {
                rows: vec![vec![1, 0, 2, 0, 3]],
                max_len: 8,
                null_bitmap: None,
            }],
        };

        let enc = serialize_bulk_insert_payload_v2(&payload).expect("serialize v2");
        assert_eq!(&enc[..4], b"BLK2");
        let dec = parse_bulk_insert_payload(&enc).expect("parse v2");

        match &dec.column_data[0] {
            BulkColumnData::Binary { rows, max_len, .. } => {
                assert_eq!(*max_len, 8);
                assert_eq!(rows[0], vec![1, 0, 2, 0, 3]);
            }
            _ => panic!("expected Binary"),
        }
    }

    #[test]
    fn parse_v2_accepts_variable_binary_when_max_len_zero() {
        let payload = BulkInsertPayload {
            table: "files".to_string(),
            columns: vec![BulkColumnSpec {
                name: "payload".to_string(),
                col_type: BulkColumnType::Binary,
                nullable: false,
                max_len: 0,
            }],
            row_count: 1,
            column_data: vec![BulkColumnData::Binary {
                rows: vec![vec![9, 8, 0, 7, 6]],
                max_len: 0,
                null_bitmap: None,
            }],
        };

        let enc = serialize_bulk_insert_payload_v2(&payload).expect("serialize v2");
        let dec = parse_bulk_insert_payload(&enc).expect("parse v2");

        match &dec.column_data[0] {
            BulkColumnData::Binary { rows, max_len, .. } => {
                assert_eq!(*max_len, 0);
                assert_eq!(rows[0], vec![9, 8, 0, 7, 6]);
            }
            _ => panic!("expected Binary"),
        }
    }

    #[test]
    fn parse_v2_rejects_cell_over_column_max_len() {
        let mut enc = Vec::new();
        enc.extend_from_slice(b"BLK2");
        enc.extend_from_slice(&2u16.to_le_bytes());
        enc.extend_from_slice(&0u16.to_le_bytes());
        enc.extend_from_slice(&1u32.to_le_bytes());
        enc.extend_from_slice(b"t");
        enc.extend_from_slice(&1u32.to_le_bytes());
        enc.extend_from_slice(&1u32.to_le_bytes());
        enc.extend_from_slice(b"b");
        enc.push(TAG_BINARY);
        enc.push(0);
        enc.extend_from_slice(&2u32.to_le_bytes());
        enc.extend_from_slice(&1u32.to_le_bytes());
        enc.extend_from_slice(&3u32.to_le_bytes());
        enc.extend_from_slice(&[1, 2, 3]);

        let e = parse_bulk_insert_payload(&enc).expect_err("max len");
        assert!(e.to_string().contains("exceeds column max_len"));
    }

    #[test]
    fn parse_v2_rejects_truncated_variable_cell() {
        let mut enc = Vec::new();
        enc.extend_from_slice(b"BLK2");
        enc.extend_from_slice(&2u16.to_le_bytes());
        enc.extend_from_slice(&0u16.to_le_bytes());
        enc.extend_from_slice(&1u32.to_le_bytes());
        enc.extend_from_slice(b"t");
        enc.extend_from_slice(&1u32.to_le_bytes());
        enc.extend_from_slice(&1u32.to_le_bytes());
        enc.extend_from_slice(b"b");
        enc.push(TAG_BINARY);
        enc.push(0);
        enc.extend_from_slice(&8u32.to_le_bytes());
        enc.extend_from_slice(&1u32.to_le_bytes());
        enc.extend_from_slice(&4u32.to_le_bytes());
        enc.extend_from_slice(&[1, 2]);

        let e = parse_bulk_insert_payload(&enc).expect_err("truncated");
        assert!(e.to_string().contains("truncated"));
    }

    #[test]
    fn null_bitmap_size_table() {
        assert_eq!(null_bitmap_size(0), 0);
        assert_eq!(null_bitmap_size(1), 1);
        assert_eq!(null_bitmap_size(8), 1);
        assert_eq!(null_bitmap_size(9), 2);
    }

    #[test]
    fn is_null_strict_errors_on_bad_row() {
        let e = is_null_strict(&[0u8], 1, 1).expect_err("out of range");
        assert!(e.to_string().contains("out of range"));
    }

    #[test]
    fn is_null_strict_errors_on_truncated_bitmap() {
        let e = is_null_strict(&[], 0, 1).expect_err("truncated");
        assert!(e.to_string().contains("null bitmap truncated"));
    }

    #[test]
    fn serialize_rejects_too_many_rows() {
        let p = BulkInsertPayload {
            table: "t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "a".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            }],
            row_count: (MAX_BULK_ROWS as u32).saturating_add(1),
            column_data: vec![BulkColumnData::I32 {
                values: vec![],
                null_bitmap: None,
            }],
        };
        let e = serialize_bulk_insert_payload(&p).expect_err("rows");
        assert!(e.to_string().contains("MAX_BULK_ROWS"));
    }

    #[test]
    fn serialize_rejects_max_len_too_large() {
        let p = BulkInsertPayload {
            table: "t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "a".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: MAX_BULK_CELL_LEN + 1,
            }],
            row_count: 0,
            column_data: vec![BulkColumnData::I32 {
                values: vec![],
                null_bitmap: None,
            }],
        };
        let e = serialize_bulk_insert_payload(&p).expect_err("max_len");
        assert!(e.to_string().contains("MAX_BULK_CELL_LEN"));
    }

    #[test]
    fn parse_rejects_unknown_column_type_tag() {
        let mut v = Vec::new();
        v.extend_from_slice(&1u32.to_le_bytes());
        v.extend_from_slice(b"t");
        v.extend_from_slice(&1u32.to_le_bytes());
        v.extend_from_slice(&1u32.to_le_bytes());
        v.extend_from_slice(b"a");
        v.push(0xFFu8);
        v.push(0u8);
        v.extend_from_slice(&0u32.to_le_bytes());
        v.extend_from_slice(&0u32.to_le_bytes());
        let e = parse_bulk_insert_payload(&v).expect_err("type tag");
        assert!(e.to_string().contains("Unknown bulk column type tag"));
    }

    #[test]
    fn parse_rejects_trailing_garbage() {
        let p = serialize_bulk_insert_payload(&BulkInsertPayload {
            table: "t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "a".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            }],
            row_count: 0,
            column_data: vec![BulkColumnData::I32 {
                values: vec![],
                null_bitmap: None,
            }],
        })
        .expect("ok");
        let mut w = p;
        w.push(0);
        let e = parse_bulk_insert_payload(&w).expect_err("mismatch");
        assert!(e.to_string().contains("length mismatch"));
    }

    #[test]
    fn is_null_reads_packed_bits() {
        let bmp = [0b101];
        assert!(is_null(&bmp, 0));
        assert!(!is_null(&bmp, 1));
        assert!(is_null(&bmp, 2));
    }

    #[test]
    fn is_null_returns_false_when_row_byte_index_outside_bitmap() {
        let bmp = [0xFF];
        assert!(!is_null(&bmp, 8));
    }

    #[test]
    fn is_null_strict_reads_bit_within_row_count() {
        let bmp = [0b100];
        assert!(is_null_strict(&bmp, 2, 3).unwrap());
        assert!(!is_null_strict(&bmp, 0, 3).unwrap());
    }

    #[test]
    fn bulk_column_type_tag_roundtrip_all_variants() {
        for t in [
            BulkColumnType::I32,
            BulkColumnType::I64,
            BulkColumnType::Text,
            BulkColumnType::Decimal,
            BulkColumnType::Binary,
            BulkColumnType::Timestamp,
        ] {
            let tag = t.to_tag();
            assert_eq!(BulkColumnType::from_tag(tag).unwrap(), t);
        }
    }

    #[test]
    fn should_roundtrip_i64_when_legacy_wire() {
        let payload = BulkInsertPayload {
            table: "t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "n".to_string(),
                col_type: BulkColumnType::I64,
                nullable: false,
                max_len: 0,
            }],
            row_count: 2,
            column_data: vec![BulkColumnData::I64 {
                values: vec![i64::MIN, i64::MAX],
                null_bitmap: None,
            }],
        };
        let enc = serialize_bulk_insert_payload(&payload).expect("serialize");
        let dec = parse_bulk_insert_payload(&enc).expect("parse");
        match &dec.column_data[0] {
            BulkColumnData::I64 { values, .. } => {
                assert_eq!(values.as_slice(), &[i64::MIN, i64::MAX]);
            }
            _ => panic!("expected I64"),
        }
    }

    #[test]
    fn should_roundtrip_timestamp_when_v2_wire() {
        let ts = BulkTimestamp {
            year: 2024,
            month: 6,
            day: 15,
            hour: 10,
            minute: 30,
            second: 45,
            fraction: 123_456,
        };
        let payload = BulkInsertPayload {
            table: "events".to_string(),
            columns: vec![BulkColumnSpec {
                name: "at".to_string(),
                col_type: BulkColumnType::Timestamp,
                nullable: true,
                max_len: 0,
            }],
            row_count: 1,
            column_data: vec![BulkColumnData::Timestamp {
                values: vec![ts],
                null_bitmap: Some(vec![0]),
            }],
        };
        let enc = serialize_bulk_insert_payload_v2(&payload).expect("serialize v2");
        let dec = parse_bulk_insert_payload(&enc).expect("parse v2");
        match &dec.column_data[0] {
            BulkColumnData::Timestamp { values, .. } => assert_eq!(values[0], ts),
            _ => panic!("expected Timestamp"),
        }
    }

    #[test]
    fn should_reject_v2_when_version_not_two() {
        let mut enc = Vec::new();
        enc.extend_from_slice(b"BLK2");
        enc.extend_from_slice(&1u16.to_le_bytes());
        enc.extend_from_slice(&0u16.to_le_bytes());
        let err = parse_bulk_insert_payload(&enc).expect_err("bad version");
        assert!(err
            .to_string()
            .contains("Unsupported bulk insert payload version"));
    }

    #[test]
    fn should_reject_v2_when_flags_nonzero() {
        let mut enc = Vec::new();
        enc.extend_from_slice(b"BLK2");
        enc.extend_from_slice(&BULK_V2_VERSION.to_le_bytes());
        enc.extend_from_slice(&1u16.to_le_bytes());
        let err = parse_bulk_insert_payload(&enc).expect_err("bad flags");
        assert!(err
            .to_string()
            .contains("Unsupported bulk insert payload flags"));
    }

    #[test]
    fn should_reject_parse_when_column_count_exceeds_max() {
        let mut v = Vec::new();
        v.extend_from_slice(&1u32.to_le_bytes());
        v.extend_from_slice(b"t");
        v.extend_from_slice(&((MAX_BULK_COLUMNS as u32) + 1).to_le_bytes());
        let err = parse_bulk_insert_payload(&v).expect_err("columns");
        assert!(err.to_string().contains("MAX_BULK_COLUMNS"));
    }

    #[test]
    fn should_reject_variable_cell_when_exceeds_max_bulk_cell_len() {
        let mut enc = Vec::new();
        enc.extend_from_slice(b"BLK2");
        enc.extend_from_slice(&BULK_V2_VERSION.to_le_bytes());
        enc.extend_from_slice(&0u16.to_le_bytes());
        enc.extend_from_slice(&1u32.to_le_bytes());
        enc.extend_from_slice(b"t");
        enc.extend_from_slice(&1u32.to_le_bytes());
        enc.extend_from_slice(&1u32.to_le_bytes());
        enc.extend_from_slice(b"b");
        enc.push(TAG_BINARY);
        enc.push(0);
        enc.extend_from_slice(&0u32.to_le_bytes());
        enc.extend_from_slice(&1u32.to_le_bytes());
        enc.extend_from_slice(&(MAX_BULK_CELL_LEN as u32 + 1).to_le_bytes());
        let err = parse_bulk_insert_payload(&enc).expect_err("cell len");
        assert!(err.to_string().contains("MAX_BULK_CELL_LEN"));
    }

    #[test]
    fn should_error_when_serialize_column_data_mismatch() {
        let payload = BulkInsertPayload {
            table: "t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "a".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            }],
            row_count: 1,
            column_data: vec![BulkColumnData::Text {
                rows: vec![b"x".to_vec()],
                max_len: 4,
                null_bitmap: None,
            }],
        };
        let err = serialize_bulk_insert_payload(&payload).expect_err("mismatch");
        assert!(err.to_string().contains("does not match spec"));
    }
}

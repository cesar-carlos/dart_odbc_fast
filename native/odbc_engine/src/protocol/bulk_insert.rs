use crate::error::{OdbcError, Result};
use std::str;

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
    let v = u32::from_le_bytes([data[*offset], data[*offset + 1], data[*offset + 2], data[*offset + 3]]);
    *offset += 4;
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

fn null_bitmap_size(n: usize) -> usize {
    n.div_ceil(8)
}

pub(crate) fn is_null(bitmap: &[u8], row: usize) -> bool {
    if row / 8 >= bitmap.len() {
        return false;
    }
    (bitmap[row / 8] & (1u8 << (row % 8))) != 0
}

pub fn parse_bulk_insert_payload(data: &[u8]) -> Result<BulkInsertPayload> {
    let mut o = 0usize;

    let table_len = read_u32_le(data, &mut o)? as usize;
    let table_bytes = read_bytes(data, &mut o, table_len)?;
    let table = str::from_utf8(table_bytes).map_err(|_| {
        OdbcError::ValidationError("Bulk insert table name invalid UTF-8".to_string())
    })?;
    let table = table.to_string();

    let col_count = read_u32_le(data, &mut o)? as usize;
    let mut columns = Vec::with_capacity(col_count);
    for _ in 0..col_count {
        let name_len = read_u32_le(data, &mut o)? as usize;
        let name_bytes = read_bytes(data, &mut o, name_len)?;
        let name = str::from_utf8(name_bytes).map_err(|_| {
            OdbcError::ValidationError("Bulk insert column name invalid UTF-8".to_string())
        })?;
        let name = name.to_string();
        if data.len() <= o {
            return Err(OdbcError::ValidationError(
                "Bulk insert payload truncated (column spec)".to_string(),
            ));
        }
        let type_tag = data[o];
        o += 1;
        let nullable = if data.len() <= o {
            return Err(OdbcError::ValidationError(
                "Bulk insert payload truncated (nullable)".to_string(),
            ));
        } else {
            data[o] != 0
        };
        o += 1;
        let max_len = read_u32_le(data, &mut o)? as usize;
        let col_type = BulkColumnType::from_tag(type_tag)?;
        columns.push(BulkColumnSpec {
            name,
            col_type,
            nullable,
            max_len,
        });
    }

    let row_count = read_u32_le(data, &mut o)? as usize;

    let mut column_data = Vec::with_capacity(columns.len());
    for spec in &columns {
        let (data_col, consumed) = parse_column_data(data, o, spec, row_count)?;
        column_data.push(data_col);
        o += consumed;
    }

    if o != data.len() {
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

fn parse_column_data(
    data: &[u8],
    start: usize,
    spec: &BulkColumnSpec,
    row_count: usize,
) -> Result<(BulkColumnData, usize)> {
    let mut o = start;

    match &spec.col_type {
        BulkColumnType::I32 => {
            let null_bitmap = if spec.nullable {
                let sz = null_bitmap_size(row_count);
                let b = read_bytes(data, &mut o, sz)?.to_vec();
                Some(b)
            } else {
                None
            };
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
            let null_bitmap = if spec.nullable {
                let sz = null_bitmap_size(row_count);
                let b = read_bytes(data, &mut o, sz)?.to_vec();
                Some(b)
            } else {
                None
            };
            let mut values = Vec::with_capacity(row_count);
            for _ in 0..row_count {
                if data.len().saturating_sub(o) < 8 {
                    return Err(OdbcError::ValidationError(
                        "Bulk insert payload truncated (i64)".to_string(),
                    ));
                }
                let v = i64::from_le_bytes([
                    data[o], data[o + 1], data[o + 2], data[o + 3],
                    data[o + 4], data[o + 5], data[o + 6], data[o + 7],
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
            let null_bitmap = if spec.nullable {
                let sz = null_bitmap_size(row_count);
                Some(read_bytes(data, &mut o, sz)?.to_vec())
            } else {
                None
            };
            let max_len = spec.max_len.max(1);
            let mut rows = Vec::with_capacity(row_count);
            for _ in 0..row_count {
                let raw = read_bytes(data, &mut o, max_len)?;
                let mut v = raw.to_vec();
                if let Some(trimmed) = v.iter().position(|&b| b == 0) {
                    v.truncate(trimmed);
                }
                rows.push(v);
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
            let null_bitmap = if spec.nullable {
                let sz = null_bitmap_size(row_count);
                Some(read_bytes(data, &mut o, sz)?.to_vec())
            } else {
                None
            };
            let max_len = spec.max_len.max(1);
            let mut rows = Vec::with_capacity(row_count);
            for _ in 0..row_count {
                let raw = read_bytes(data, &mut o, max_len)?;
                let mut v = raw.to_vec();
                if let Some(trimmed) = v.iter().position(|&b| b == 0) {
                    v.truncate(trimmed);
                }
                rows.push(v);
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
            let null_bitmap = if spec.nullable {
                let sz = null_bitmap_size(row_count);
                let b = read_bytes(data, &mut o, sz)?.to_vec();
                Some(b)
            } else {
                None
            };
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
                let fraction = u32::from_le_bytes([
                    data[o + 12], data[o + 13], data[o + 14], data[o + 15],
                ]);
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

pub fn serialize_bulk_insert_payload(payload: &BulkInsertPayload) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    let table_b = payload.table.as_bytes();
    out.extend_from_slice(&(table_b.len() as u32).to_le_bytes());
    out.extend_from_slice(table_b);
    out.extend_from_slice(&(payload.columns.len() as u32).to_le_bytes());

    for spec in &payload.columns {
        let name_b = spec.name.as_bytes();
        out.extend_from_slice(&(name_b.len() as u32).to_le_bytes());
        out.extend_from_slice(name_b);
        out.push(spec.col_type.to_tag());
        out.push(if spec.nullable { 1 } else { 0 });
        out.extend_from_slice(&(spec.max_len as u32).to_le_bytes());
    }

    out.extend_from_slice(&payload.row_count.to_le_bytes());

    for (spec, data) in payload.columns.iter().zip(payload.column_data.iter()) {
        serialize_column_data(&mut out, spec, data, payload.row_count as usize)?;
    }

    Ok(out)
}

fn serialize_column_data(
    out: &mut Vec<u8>,
    spec: &BulkColumnSpec,
    data: &BulkColumnData,
    _row_count: usize,
) -> Result<()> {
    match (data, &spec.col_type) {
        (BulkColumnData::I32 { values, null_bitmap }, BulkColumnType::I32) => {
            if let Some(bm) = null_bitmap {
                out.extend_from_slice(bm);
            }
            for &v in values {
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
        (BulkColumnData::I64 { values, null_bitmap }, BulkColumnType::I64) => {
            if let Some(bm) = null_bitmap {
                out.extend_from_slice(bm);
            }
            for &v in values {
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
        (BulkColumnData::Text { rows, max_len, null_bitmap }, BulkColumnType::Text)
        | (BulkColumnData::Text { rows, max_len, null_bitmap }, BulkColumnType::Decimal) => {
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
        (BulkColumnData::Binary { rows, max_len, null_bitmap }, BulkColumnType::Binary) => {
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
        (BulkColumnData::Timestamp { values, null_bitmap }, BulkColumnType::Timestamp) => {
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
            BulkColumnData::I32 { values, null_bitmap } => {
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
            BulkColumnData::I32 { values, null_bitmap } => {
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
}

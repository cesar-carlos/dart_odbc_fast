use crate::error::{OdbcError, Result};

use super::common::{
    read_bytes, read_null_bitmap, read_u32_le, BulkColumnData, BulkColumnSpec, BulkColumnType,
    BulkTimestamp,
};

pub(crate) fn parse_column_data(
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

pub(crate) fn trim_legacy_nul_padded_cell(raw: &[u8]) -> &[u8] {
    let end = raw.iter().position(|&b| b == 0).unwrap_or(raw.len());
    &raw[..end]
}

pub(crate) fn serialize_column_data(
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

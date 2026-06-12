use crate::error::{OdbcError, Result};
use crate::protocol::bulk_insert::{
    is_null, BulkColumnData, BulkColumnSpec, BulkColumnType, BulkTimestamp,
};
use odbc_api::buffers::BufferDesc;
use odbc_api::handles::AsStatementRef;
use odbc_api::sys::NULL_DATA;

pub(super) fn spec_to_buffer_desc(spec: &BulkColumnSpec) -> Result<BufferDesc> {
    let nullable = spec.nullable;
    let max_len = spec.max_len.max(1);
    Ok(match &spec.col_type {
        BulkColumnType::I32 => BufferDesc::I32 { nullable },
        BulkColumnType::I64 => BufferDesc::I64 { nullable },
        BulkColumnType::Text | BulkColumnType::Decimal => BufferDesc::Text {
            max_str_len: max_len,
        },
        BulkColumnType::Binary => BufferDesc::Binary { length: max_len },
        BulkColumnType::Timestamp => BufferDesc::Timestamp { nullable },
    })
}

pub(super) fn fill_column<S>(
    inserter: &mut odbc_api::ColumnarBulkInserter<S, odbc_api::buffers::AnyBuffer>,
    buf_idx: usize,
    spec: &BulkColumnSpec,
    data: &BulkColumnData,
    chunk_start: usize,
    chunk_len: usize,
) -> Result<()>
where
    S: AsStatementRef,
{
    match (data, &spec.col_type) {
        (
            BulkColumnData::I32 {
                values,
                null_bitmap,
            },
            BulkColumnType::I32,
        ) => {
            if let Some(bm) = null_bitmap {
                let mut writer = inserter
                    .column_mut(buf_idx)
                    .as_nullable_slice::<i32>()
                    .ok_or_else(|| {
                        OdbcError::InternalError("I32 nullable column expected".to_string())
                    })?;
                let (vals, inds) = writer.raw_values();
                for (i, &v) in values[chunk_start..chunk_start + chunk_len]
                    .iter()
                    .enumerate()
                {
                    vals[i] = v;
                    inds[i] = if is_null(bm, chunk_start + i) {
                        NULL_DATA
                    } else {
                        0
                    };
                }
            } else {
                let col = inserter
                    .column_mut(buf_idx)
                    .as_slice::<i32>()
                    .ok_or_else(|| OdbcError::InternalError("I32 column expected".to_string()))?;
                col[..chunk_len].copy_from_slice(&values[chunk_start..chunk_start + chunk_len]);
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
                let mut writer = inserter
                    .column_mut(buf_idx)
                    .as_nullable_slice::<i64>()
                    .ok_or_else(|| {
                        OdbcError::InternalError("I64 nullable column expected".to_string())
                    })?;
                let (vals, inds) = writer.raw_values();
                for (i, &v) in values[chunk_start..chunk_start + chunk_len]
                    .iter()
                    .enumerate()
                {
                    vals[i] = v;
                    inds[i] = if is_null(bm, chunk_start + i) {
                        NULL_DATA
                    } else {
                        0
                    };
                }
            } else {
                let col = inserter
                    .column_mut(buf_idx)
                    .as_slice::<i64>()
                    .ok_or_else(|| OdbcError::InternalError("I64 column expected".to_string()))?;
                col[..chunk_len].copy_from_slice(&values[chunk_start..chunk_start + chunk_len]);
            }
        }
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
            let mut view = inserter
                .column_mut(buf_idx)
                .as_text_view()
                .ok_or_else(|| OdbcError::InternalError("Text column expected".to_string()))?;
            for (i, r) in (chunk_start..chunk_start + chunk_len).enumerate() {
                let cell = if null_bitmap.as_ref().is_some_and(|bm| is_null(bm, r)) {
                    None
                } else {
                    let bytes = rows[r].as_slice();
                    if bytes.is_empty() {
                        Some(&[][..])
                    } else {
                        Some(bytes)
                    }
                };
                view.set_cell(i, cell);
            }
        }
        (
            BulkColumnData::Binary {
                rows, null_bitmap, ..
            },
            BulkColumnType::Binary,
        ) => {
            let mut view = inserter
                .column_mut(buf_idx)
                .as_bin_view()
                .ok_or_else(|| OdbcError::InternalError("Binary column expected".to_string()))?;
            for (i, r) in (chunk_start..chunk_start + chunk_len).enumerate() {
                let cell = if null_bitmap.as_ref().is_some_and(|bm| is_null(bm, r)) {
                    None
                } else {
                    let bytes = rows[r].as_slice();
                    if bytes.is_empty() {
                        Some(&[][..])
                    } else {
                        Some(bytes)
                    }
                };
                view.set_cell(i, cell);
            }
        }
        (
            BulkColumnData::Timestamp {
                values,
                null_bitmap,
            },
            BulkColumnType::Timestamp,
        ) => {
            let ts = |t: &BulkTimestamp| odbc_api::sys::Timestamp {
                year: t.year,
                month: t.month,
                day: t.day,
                hour: t.hour,
                minute: t.minute,
                second: t.second,
                fraction: t.fraction,
            };
            if let Some(bm) = null_bitmap {
                let mut writer = inserter
                    .column_mut(buf_idx)
                    .as_nullable_slice::<odbc_api::sys::Timestamp>()
                    .ok_or_else(|| {
                        OdbcError::InternalError("Timestamp nullable column expected".to_string())
                    })?;
                let (vals, inds) = writer.raw_values();
                for (i, r) in (chunk_start..chunk_start + chunk_len).enumerate() {
                    vals[i] = ts(&values[r]);
                    inds[i] = if is_null(bm, r) { NULL_DATA } else { 0 };
                }
            } else {
                let col = inserter
                    .column_mut(buf_idx)
                    .as_slice::<odbc_api::sys::Timestamp>()
                    .ok_or_else(|| {
                        OdbcError::InternalError("Timestamp column expected".to_string())
                    })?;
                for (i, r) in (chunk_start..chunk_start + chunk_len).enumerate() {
                    col[i] = ts(&values[r]);
                }
            }
        }
        _ => {
            return Err(OdbcError::ValidationError(
                "Column data does not match spec".to_string(),
            ));
        }
    }
    Ok(())
}

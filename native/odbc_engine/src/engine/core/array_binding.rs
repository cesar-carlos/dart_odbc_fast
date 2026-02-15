use crate::error::{OdbcError, Result};
use crate::protocol::bulk_insert::{
    is_null, BulkColumnData, BulkColumnSpec, BulkColumnType, BulkInsertPayload, BulkTimestamp,
};
use odbc_api::handles::AsStatementRef;
use odbc_api::sys::NULL_DATA;
use odbc_api::{buffers::BufferDesc, Connection};
use std::iter::once;

const DEFAULT_PARAMSET_SIZE: usize = 1000;

pub(crate) fn validate_i32_bulk_data(columns: &[&str], data: &[Vec<i32>]) -> Result<()> {
    let n_cols = columns.len();
    if data.len() != n_cols {
        return Err(OdbcError::ValidationError(
            "data length must match columns length".to_string(),
        ));
    }
    if data.is_empty() {
        return Ok(());
    }
    let n_rows = data[0].len();
    for col in data.iter().skip(1) {
        if col.len() != n_rows {
            return Err(OdbcError::ValidationError(
                "all columns must have same row count".to_string(),
            ));
        }
    }
    Ok(())
}

pub struct ArrayBinding {
    paramset_size: usize,
}

impl ArrayBinding {
    pub fn new(paramset_size: usize) -> Self {
        Self {
            paramset_size: paramset_size.max(1),
        }
    }

    pub fn paramset_size(&self) -> usize {
        self.paramset_size
    }

    pub fn bulk_insert_i32(
        &self,
        conn: &Connection<'static>,
        table: &str,
        columns: &[&str],
        data: &[Vec<i32>],
    ) -> Result<usize> {
        validate_i32_bulk_data(columns, data)?;
        let n_cols = columns.len();
        if n_cols == 0 {
            return Ok(0);
        }
        let n_rows = data[0].len();
        if n_rows == 0 {
            return Ok(0);
        }

        let placeholders = once("?")
            .cycle()
            .take(n_cols)
            .collect::<Vec<_>>()
            .join(", ");
        let col_list = columns.join(", ");
        let sql = format!(
            "INSERT INTO {} ({}) VALUES ({})",
            table, col_list, placeholders
        );

        let prepared = conn.prepare(&sql).map_err(OdbcError::from)?;
        let descs: Vec<BufferDesc> = (0..n_cols)
            .map(|_| BufferDesc::I32 { nullable: false })
            .collect();
        let capacity = self.paramset_size.min(n_rows);
        let mut inserter = prepared
            .into_column_inserter(capacity, descs)
            .map_err(OdbcError::from)?;

        let mut total = 0;
        for chunk_start in (0..n_rows).step_by(capacity) {
            let end = (chunk_start + capacity).min(n_rows);
            let chunk_len = end - chunk_start;
            inserter.set_num_rows(chunk_len);

            for (buf_idx, col_data) in data.iter().enumerate() {
                let col = inserter
                    .column_mut(buf_idx)
                    .as_slice::<i32>()
                    .ok_or_else(|| OdbcError::InternalError("I32 column expected".to_string()))?;
                col[..chunk_len].copy_from_slice(&col_data[chunk_start..end]);
            }

            inserter.execute().map_err(OdbcError::from)?;
            total += chunk_len;
        }

        Ok(total)
    }

    pub fn bulk_insert_i32_text(
        &self,
        conn: &Connection<'static>,
        table: &str,
        columns: &[&str],
        ids: &[i32],
        names: &[String],
        max_str_len: usize,
    ) -> Result<usize> {
        if ids.len() != names.len() {
            return Err(OdbcError::ValidationError(
                "ids and names must have same length".to_string(),
            ));
        }
        let n_rows = ids.len();
        if n_rows == 0 {
            return Ok(0);
        }

        let sql = format!(
            "INSERT INTO {} ({}, {}) VALUES (?, ?)",
            table, columns[0], columns[1]
        );
        let prepared = conn.prepare(&sql).map_err(OdbcError::from)?;
        let descs = [
            BufferDesc::I32 { nullable: false },
            BufferDesc::Text {
                max_str_len: max_str_len.max(1),
            },
        ];
        let capacity = self.paramset_size.min(n_rows);
        let mut inserter = prepared
            .into_column_inserter(capacity, descs)
            .map_err(OdbcError::from)?;

        let mut total = 0;
        for chunk_start in (0..n_rows).step_by(capacity) {
            let end = (chunk_start + capacity).min(n_rows);
            let chunk_len = end - chunk_start;
            inserter.set_num_rows(chunk_len);

            {
                let id_col = inserter
                    .column_mut(0)
                    .as_slice::<i32>()
                    .ok_or_else(|| OdbcError::InternalError("I32 column expected".to_string()))?;
                id_col[..chunk_len].copy_from_slice(&ids[chunk_start..end]);
            }
            {
                let mut name_col = inserter
                    .column_mut(1)
                    .as_text_view()
                    .ok_or_else(|| OdbcError::InternalError("Text column expected".to_string()))?;
                for (i, name) in names[chunk_start..end].iter().enumerate() {
                    name_col.set_cell(i, Some(name.as_bytes()));
                }
            }

            inserter.execute().map_err(OdbcError::from)?;
            total += chunk_len;
        }

        Ok(total)
    }

    pub fn bulk_insert_generic(
        &self,
        conn: &Connection<'static>,
        payload: &BulkInsertPayload,
    ) -> Result<usize> {
        let n_rows = payload.row_count as usize;
        if n_rows == 0 {
            return Ok(0);
        }
        let n_cols = payload.columns.len();
        if payload.column_data.len() != n_cols {
            return Err(OdbcError::ValidationError(
                "column_data length must match columns length".to_string(),
            ));
        }

        let col_list: String = payload
            .columns
            .iter()
            .map(|s| s.name.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        let placeholders = once("?")
            .cycle()
            .take(n_cols)
            .collect::<Vec<_>>()
            .join(", ");
        let sql = format!(
            "INSERT INTO {} ({}) VALUES ({})",
            payload.table, col_list, placeholders
        );

        let descs: Vec<BufferDesc> = payload
            .columns
            .iter()
            .map(spec_to_buffer_desc)
            .collect::<Result<Vec<_>>>()?;

        let capacity = self.paramset_size.min(n_rows);
        let prepared = conn.prepare(&sql).map_err(OdbcError::from)?;
        let mut inserter = prepared
            .into_column_inserter(capacity, descs)
            .map_err(OdbcError::from)?;

        let mut total = 0_usize;
        for chunk_start in (0..n_rows).step_by(capacity) {
            let end = (chunk_start + capacity).min(n_rows);
            let chunk_len = end - chunk_start;
            inserter.set_num_rows(chunk_len);

            for (buf_idx, (spec, data)) in payload
                .columns
                .iter()
                .zip(payload.column_data.iter())
                .enumerate()
            {
                fill_column(&mut inserter, buf_idx, spec, data, chunk_start, chunk_len)?;
            }

            inserter.execute().map_err(OdbcError::from)?;
            total += chunk_len;
        }

        Ok(total)
    }
}

fn spec_to_buffer_desc(spec: &BulkColumnSpec) -> Result<BufferDesc> {
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

fn fill_column<S>(
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
                    let bytes = &rows[r];
                    if bytes.is_empty() {
                        Some(&[][..])
                    } else {
                        Some(bytes.as_slice())
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
                    let bytes = &rows[r];
                    if bytes.is_empty() {
                        Some(&[][..])
                    } else {
                        Some(bytes.as_slice())
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

impl Default for ArrayBinding {
    fn default() -> Self {
        Self::new(DEFAULT_PARAMSET_SIZE)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::OdbcError;

    #[test]
    fn test_validate_i32_bulk_data_mismatched_columns() {
        let columns = ["a", "b"];
        let data: Vec<Vec<i32>> = vec![vec![1], vec![2], vec![3]];
        let r = validate_i32_bulk_data(&columns, &data);
        assert!(r.is_err());
        assert!(matches!(r.unwrap_err(), OdbcError::ValidationError(_)));
    }

    #[test]
    fn test_validate_i32_bulk_data_different_column_lengths() {
        let columns = ["a", "b"];
        let data: Vec<Vec<i32>> = vec![vec![1, 2], vec![3]];
        let r = validate_i32_bulk_data(&columns, &data);
        assert!(r.is_err());
        assert!(matches!(r.unwrap_err(), OdbcError::ValidationError(_)));
    }

    #[test]
    fn test_validate_i32_bulk_data_zero_rows() {
        let columns = ["a", "b"];
        let data: Vec<Vec<i32>> = vec![vec![], vec![]];
        let r = validate_i32_bulk_data(&columns, &data);
        assert!(r.is_ok());
    }

    #[test]
    fn test_validate_i32_bulk_data_valid() {
        let columns = ["a", "b"];
        let data: Vec<Vec<i32>> = vec![vec![1, 2, 3], vec![4, 5, 6]];
        let r = validate_i32_bulk_data(&columns, &data);
        assert!(r.is_ok());
    }

    #[test]
    fn test_array_binding_new() {
        let ab = ArrayBinding::new(500);
        assert_eq!(ab.paramset_size(), 500);
    }

    #[test]
    fn test_array_binding_default() {
        let ab = ArrayBinding::default();
        assert_eq!(ab.paramset_size(), DEFAULT_PARAMSET_SIZE);
    }

    #[test]
    fn test_array_binding_min_size_one() {
        let ab = ArrayBinding::new(0);
        assert_eq!(ab.paramset_size(), 1);
    }
}

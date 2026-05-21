use crate::engine::identifier::{quote_identifier_default, quote_qualified_default};
use crate::error::{OdbcError, Result};
use crate::protocol::bulk_insert::{
    is_null, BulkColumnData, BulkColumnSpec, BulkColumnType, BulkInsertPayload, BulkTimestamp,
};
use odbc_api::handles::AsStatementRef;
use odbc_api::sys::NULL_DATA;
use odbc_api::{buffers::BufferDesc, Connection};

/// Validate and quote each `&str` in `columns`, returning a comma-separated
/// list ready to inject into a SQL `INSERT (...)` clause.
///
/// A2 fix: every column identifier passes through `quote_identifier_default`
/// before reaching the wire, eliminating SQL injection vectors.
fn quote_column_list(columns: &[&str]) -> Result<String> {
    let mut out = String::with_capacity(columns.len().saturating_mul(8));
    for (idx, c) in columns.iter().enumerate() {
        if idx > 0 {
            out.push_str(", ");
        }
        out.push_str(&quote_identifier_default(c)?);
    }
    Ok(out)
}

fn placeholders(n_cols: usize) -> String {
    let mut out = String::with_capacity(n_cols.saturating_mul(3).saturating_sub(2));
    for idx in 0..n_cols {
        if idx > 0 {
            out.push_str(", ");
        }
        out.push('?');
    }
    out
}

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

        let placeholders = placeholders(n_cols);
        let col_list = quote_column_list(columns)?;
        let qtable = quote_qualified_default(table)?;
        let sql = format!("INSERT INTO {qtable} ({col_list}) VALUES ({placeholders})");

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

        let qtable = quote_qualified_default(table)?;
        let qcol0 = quote_identifier_default(columns[0])?;
        let qcol1 = quote_identifier_default(columns[1])?;
        let sql = format!("INSERT INTO {qtable} ({qcol0}, {qcol1}) VALUES (?, ?)");
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
        self.bulk_insert_generic_range(conn, payload, 0, payload.row_count as usize)
    }

    pub fn bulk_insert_generic_range(
        &self,
        conn: &Connection<'static>,
        payload: &BulkInsertPayload,
        start: usize,
        end: usize,
    ) -> Result<usize> {
        let total_rows = payload.row_count as usize;
        if start > end || end > total_rows {
            return Err(OdbcError::ValidationError(
                "Invalid bulk insert range".to_string(),
            ));
        }

        let n_rows = end - start;
        if n_rows == 0 {
            return Ok(0);
        }
        let n_cols = payload.columns.len();
        if payload.column_data.len() != n_cols {
            return Err(OdbcError::ValidationError(
                "column_data length must match columns length".to_string(),
            ));
        }

        let mut col_list = String::with_capacity(payload.columns.len().saturating_mul(8));
        for (idx, s) in payload.columns.iter().enumerate() {
            if idx > 0 {
                col_list.push_str(", ");
            }
            col_list.push_str(&quote_identifier_default(&s.name)?);
        }
        let placeholders = placeholders(n_cols);
        let qtable = quote_qualified_default(&payload.table)?;
        let sql = format!("INSERT INTO {qtable} ({col_list}) VALUES ({placeholders})");

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
        for chunk_start in (start..end).step_by(capacity) {
            let chunk_end = (chunk_start + capacity).min(end);
            let chunk_len = chunk_end - chunk_start;
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

    #[test]
    fn test_placeholders_builds_without_extra_separator() {
        assert_eq!(placeholders(0), "");
        assert_eq!(placeholders(1), "?");
        assert_eq!(placeholders(3), "?, ?, ?");
    }

    #[test]
    fn should_quote_column_list_for_insert_clause() {
        let quoted = quote_column_list(&["id", "name"]).expect("quote columns");
        assert_eq!(quoted, "\"id\", \"name\"");
    }

    #[test]
    fn should_reject_mismatched_column_count_when_quoting_list() {
        let err = quote_column_list(&["bad;drop"]).unwrap_err();
        assert!(matches!(err, OdbcError::ValidationError(_)));
    }

    #[test]
    fn should_map_bulk_column_specs_to_buffer_descriptors() {
        let specs = [
            BulkColumnSpec {
                name: "a".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            },
            BulkColumnSpec {
                name: "b".to_string(),
                col_type: BulkColumnType::Text,
                nullable: true,
                max_len: 0,
            },
            BulkColumnSpec {
                name: "c".to_string(),
                col_type: BulkColumnType::Binary,
                nullable: false,
                max_len: 0,
            },
        ];
        let descs: Vec<_> = specs
            .iter()
            .map(spec_to_buffer_desc)
            .collect::<Result<Vec<_>>>()
            .expect("buffer descs");
        assert!(matches!(descs[0], BufferDesc::I32 { nullable: false }));
        assert!(matches!(descs[1], BufferDesc::Text { max_str_len: 1 }));
        assert!(matches!(descs[2], BufferDesc::Binary { length: 1 }));
    }

    #[test]
    fn should_accept_empty_columns_when_validating_i32_bulk_data() {
        assert!(validate_i32_bulk_data(&[], &[]).is_ok());
    }
}

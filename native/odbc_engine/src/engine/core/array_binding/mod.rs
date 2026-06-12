mod column_buffers;
mod insert_sql;
mod validation;

use crate::error::{OdbcError, Result};
use crate::protocol::bulk_insert::BulkInsertPayload;
use column_buffers::{fill_column, spec_to_buffer_desc};
use insert_sql::{placeholders, quote_column_list};
use odbc_api::buffers::BufferDesc;
use odbc_api::Connection;
use validation::validate_i32_bulk_data;

use crate::engine::identifier::quote_qualified_default;

const DEFAULT_PARAMSET_SIZE: usize = 1000;

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
        let qcol0 = crate::engine::identifier::quote_identifier_default(columns[0])?;
        let qcol1 = crate::engine::identifier::quote_identifier_default(columns[1])?;
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
            col_list.push_str(&crate::engine::identifier::quote_identifier_default(
                &s.name,
            )?);
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

impl Default for ArrayBinding {
    fn default() -> Self {
        Self::new(DEFAULT_PARAMSET_SIZE)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::OdbcError;
    use crate::protocol::bulk_insert::{BulkColumnSpec, BulkColumnType};

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
    fn should_quote_empty_column_list_as_empty_string() {
        assert_eq!(quote_column_list(&[]).expect("empty list"), "");
    }

    #[test]
    fn should_quote_three_column_list_for_insert_clause() {
        let quoted = quote_column_list(&["a", "b", "c"]).expect("three columns");
        assert_eq!(quoted, "\"a\", \"b\", \"c\"");
    }

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
    fn should_accept_empty_columns_when_validating_i32_bulk_data() {
        assert!(validate_i32_bulk_data(&[], &[]).is_ok());
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
    fn should_map_i64_and_timestamp_specs_to_buffer_descriptors() {
        let i64_spec = BulkColumnSpec {
            name: "big".to_string(),
            col_type: BulkColumnType::I64,
            nullable: true,
            max_len: 0,
        };
        let ts_spec = BulkColumnSpec {
            name: "ts".to_string(),
            col_type: BulkColumnType::Timestamp,
            nullable: false,
            max_len: 0,
        };
        assert!(matches!(
            spec_to_buffer_desc(&i64_spec).expect("i64 desc"),
            BufferDesc::I64 { nullable: true }
        ));
        assert!(matches!(
            spec_to_buffer_desc(&ts_spec).expect("timestamp desc"),
            BufferDesc::Timestamp { nullable: false }
        ));
    }

    #[test]
    fn should_map_decimal_spec_to_text_buffer_descriptor() {
        let spec = BulkColumnSpec {
            name: "amount".to_string(),
            col_type: BulkColumnType::Decimal,
            nullable: true,
            max_len: 24,
        };
        assert!(matches!(
            spec_to_buffer_desc(&spec).expect("decimal desc"),
            BufferDesc::Text { max_str_len: 24 }
        ));
    }

    #[test]
    fn should_use_min_str_len_one_for_text_spec_with_zero_max_len() {
        let spec = BulkColumnSpec {
            name: "note".to_string(),
            col_type: BulkColumnType::Text,
            nullable: false,
            max_len: 0,
        };
        assert!(matches!(
            spec_to_buffer_desc(&spec).expect("text desc"),
            BufferDesc::Text { max_str_len: 1 }
        ));
    }
}

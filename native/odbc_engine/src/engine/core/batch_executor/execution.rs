use crate::engine::cell_reader::CellReader;
use crate::engine::sqlserver_json::coalesce_for_json_rows;
use crate::error::{OdbcError, Result};
use crate::protocol::{OdbcType, RowBuffer, RowBufferEncoder};
use odbc_api::handles::AsStatementRef;
use odbc_api::parameter::InputParameter;
use odbc_api::{Connection, Cursor, ParameterCollectionRef, Prepared, ResultSetMetadata};

use super::BatchExecutor;

impl BatchExecutor {
    pub(super) fn execute_prepared_and_encode<S, P>(
        &self,
        stmt: &mut Prepared<S>,
        params: P,
    ) -> Result<Vec<u8>>
    where
        S: AsStatementRef,
        P: ParameterCollectionRef,
    {
        let mut cursor = stmt.execute(params).map_err(OdbcError::from)?;
        if let Some(mut c) = cursor.take() {
            return self.encode_result_cursor(&mut c);
        }
        drop(cursor);
        let row_count = stmt.row_count().map_err(OdbcError::from)?.unwrap_or(0) as i64;
        Ok(crate::protocol::encode_row_count_only(row_count))
    }

    pub(super) fn encode_result_cursor<C>(&self, cursor: &mut C) -> Result<Vec<u8>>
    where
        C: Cursor + ResultSetMetadata,
    {
        let mut row_buffer = RowBuffer::new();
        let cols_i16 = cursor.num_result_cols().map_err(OdbcError::from)?;
        let cols_u16: u16 = cols_i16
            .try_into()
            .map_err(|_| OdbcError::InternalError("Invalid column count".to_string()))?;
        let cols_usize: usize = cols_u16.into();
        let mut column_types: Vec<OdbcType> = Vec::with_capacity(cols_usize);

        for col_idx in 1..=cols_u16 {
            let col_name = cursor.col_name(col_idx).map_err(OdbcError::from)?;
            let col_type = cursor.col_data_type(col_idx).map_err(OdbcError::from)?;
            let sql_type_code = OdbcType::sql_type_code_from_data_type(&col_type);
            let odbc_type = OdbcType::from_odbc_sql_type(sql_type_code);
            row_buffer.add_column(col_name.to_string(), odbc_type);
            column_types.push(odbc_type);
        }

        let mut cell_reader = CellReader::new();
        while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
            let mut row_data = Vec::with_capacity(column_types.len());
            for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                let col_number: u16 = (col_idx + 1)
                    .try_into()
                    .map_err(|_| OdbcError::InternalError("Invalid column number".to_string()))?;
                let cell_data = cell_reader.read_cell_bytes(&mut row, col_number, odbc_type)?;
                row_data.push(cell_data);
            }
            row_buffer.add_row(row_data);
        }

        coalesce_for_json_rows(&mut row_buffer);
        RowBufferEncoder::encode_result(&row_buffer)
    }

    pub(super) fn execute_direct_param_set(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        parameters: Vec<Box<dyn InputParameter>>,
    ) -> Result<Vec<u8>> {
        let mut prealloc = conn.preallocate().map_err(OdbcError::from)?;
        let mut cursor = if parameters.is_empty() {
            prealloc.execute(sql, ()).map_err(OdbcError::from)?
        } else {
            prealloc
                .execute(sql, parameters.as_slice())
                .map_err(OdbcError::from)?
        };

        let mut taken = cursor.take();
        if taken.is_none() {
            drop(taken);
            drop(cursor);
            let row_count = prealloc.row_count().map_err(OdbcError::from)?.unwrap_or(0) as i64;
            return Ok(crate::protocol::encode_row_count_only(row_count));
        }

        let Some(mut c) = taken.take() else {
            return Err(OdbcError::InternalError(
                "Expected result cursor after successful execute".to_string(),
            ));
        };
        let mut row_buffer = RowBuffer::new();
        let cols_i16 = c.num_result_cols().map_err(OdbcError::from)?;
        let cols_u16: u16 = cols_i16
            .try_into()
            .map_err(|_| OdbcError::InternalError("Invalid column count".to_string()))?;
        let cols_usize: usize = cols_u16.into();
        let mut column_types: Vec<OdbcType> = Vec::with_capacity(cols_usize);

        for col_idx in 1..=cols_u16 {
            let col_name = c.col_name(col_idx).map_err(OdbcError::from)?;
            let col_type = c.col_data_type(col_idx).map_err(OdbcError::from)?;
            let sql_type_code = OdbcType::sql_type_code_from_data_type(&col_type);
            let odbc_type = OdbcType::from_odbc_sql_type(sql_type_code);
            row_buffer.add_column(col_name.to_string(), odbc_type);
            column_types.push(odbc_type);
        }

        let mut cell_reader = CellReader::new();
        while let Some(mut row) = c.next_row().map_err(OdbcError::from)? {
            let mut row_data = Vec::with_capacity(column_types.len());
            for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                let col_number: u16 = (col_idx + 1)
                    .try_into()
                    .map_err(|_| OdbcError::InternalError("Invalid column number".to_string()))?;
                let cell_data = cell_reader.read_cell_bytes(&mut row, col_number, odbc_type)?;
                row_data.push(cell_data);
            }
            row_buffer.add_row(row_data);
        }

        coalesce_for_json_rows(&mut row_buffer);
        RowBufferEncoder::encode_result(&row_buffer)
    }
}

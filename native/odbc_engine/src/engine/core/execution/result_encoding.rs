use super::ExecutionEngine;
use crate::engine::cell_reader::CellReader;
use crate::engine::sqlserver_json::coalesce_for_json_rows;
use crate::error::{OdbcError, Result};
use crate::plugins::DriverPlugin;
use crate::protocol::{
    row_buffer_to_columnar, ColumnarEncoder, OdbcType, RowBuffer, RowBufferEncoder,
};
use odbc_api::{Cursor, ResultSetMetadata};

/// Encodes a row buffer for query / optional-cursor paths (row-major or columnar).
pub(crate) fn encode_query_result_payload(
    row_buffer: &RowBuffer,
    use_columnar: bool,
    use_compression: bool,
) -> Result<Vec<u8>> {
    if use_columnar {
        let columnar_buffer = row_buffer_to_columnar(row_buffer)?;
        ColumnarEncoder::encode(&columnar_buffer, use_compression)
    } else {
        RowBufferEncoder::encode_result(row_buffer)
    }
}

impl ExecutionEngine {
    pub(super) fn encode_optional_cursor<C>(
        &self,
        cursor: Option<C>,
        plugin: Option<&dyn DriverPlugin>,
    ) -> Result<Vec<u8>>
    where
        C: Cursor + ResultSetMetadata,
    {
        let mut row_buffer = RowBuffer::new();

        let Some(mut cursor) = cursor else {
            // No cursor: encode an empty payload via the row-major path
            // (preserves wire-shape for callers that distinguish "empty
            // result set" from "no result set at all").
            return encode_query_result_payload(
                &row_buffer,
                self.use_columnar,
                self.use_compression,
            );
        };

        let column_types = self.describe_columns(&mut cursor, &mut row_buffer, plugin)?;

        // Sprint 2 fast path: drain the cursor straight into a
        // `RowBufferV2` (column-major) so we never materialise the
        // row-major intermediate when the consumer asked for columnar
        // bytes. Bypassed for FOR JSON queries because their post-fetch
        // coalescing relies on the row-major shape.
        #[cfg(feature = "block-cursor-fetch")]
        {
            if self.use_columnar && !crate::engine::sqlserver_json::is_for_json_result(&row_buffer)
            {
                if let Some(descs) =
                    crate::engine::core::block_fetch::plan_buffer_descs(&mut cursor, &column_types)?
                {
                    // Move column names out of `row_buffer` (it's dropped
                    // on return) into the columnar metadata vec, avoiding
                    // a per-column `String::clone`.
                    let column_metas: Vec<crate::protocol::columnar::ColumnMetadata> =
                        std::mem::take(&mut row_buffer.columns)
                            .into_iter()
                            .map(|c| crate::protocol::columnar::ColumnMetadata {
                                name: c.name,
                                odbc_type: c.odbc_type,
                            })
                            .collect();
                    let (_cursor, v2) = crate::engine::core::columnar_fetch::fetch_columnar_into(
                        cursor,
                        column_metas,
                        &column_types,
                        descs,
                        crate::engine::core::block_fetch::configured_batch_size(),
                    )?;
                    return crate::protocol::ColumnarEncoder::encode(&v2, self.use_compression);
                }
            }
        }

        let _drained = crate::engine::fetch::fetch_cursor_into_row_buffer(
            cursor,
            &column_types,
            &mut row_buffer,
        )?;

        // FOR JSON normalisation — see execute_query_inner above (closes #2).
        coalesce_for_json_rows(&mut row_buffer);

        encode_query_result_payload(&row_buffer, self.use_columnar, self.use_compression)
    }

    /// Same as [`Self::encode_cursor`], but always row-major v1 (required
    /// for `RC1\0` embedded messages on the wire).
    pub(super) fn encode_cursor_v1<C: Cursor + ResultSetMetadata>(
        &self,
        cursor: &mut C,
    ) -> Result<Vec<u8>> {
        let mut row_buffer = RowBuffer::new();
        let plugin = self.current_plugin();
        let column_types = self.describe_columns(cursor, &mut row_buffer, plugin.as_deref())?;
        // Per-cell loop is the only option here because the caller still
        // borrows `cursor` mutably (it's passed by reference, not consumed)
        // — `BlockCursor::bind_buffer` requires ownership. Ref-cursor
        // payloads are typically small and not in any hot path, so leaving
        // them on the legacy path costs nothing measurable.
        let mut cell_reader = CellReader::new();
        while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
            let mut row_data = Vec::with_capacity(column_types.len());
            for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                let col_number: u16 = (col_idx + 1)
                    .try_into()
                    .map_err(|_| OdbcError::InternalError("Invalid column number".to_string()))?;
                row_data.push(cell_reader.read_cell_bytes(&mut row, col_number, odbc_type)?);
            }
            row_buffer.add_row(row_data);
        }
        coalesce_for_json_rows(&mut row_buffer);
        RowBufferEncoder::encode_result(&row_buffer)
    }

    /// Read every row from `cursor`, encode it as a row-buffer (or columnar
    /// buffer when `use_columnar` is on) and return the bytes.
    ///
    /// Takes `&mut C` instead of consuming `C` so the caller can choose
    /// whether to drop the cursor (which calls `SQLCloseCursor` and discards
    /// pending result sets) or to consume it via `cursor.into_stmt()` (which
    /// preserves them for `SQLMoreResults`). The multi-result path uses the
    /// latter.
    pub(super) fn encode_cursor<C: Cursor + ResultSetMetadata>(
        &self,
        cursor: &mut C,
    ) -> Result<Vec<u8>> {
        let mut row_buffer = RowBuffer::new();
        let plugin = self.current_plugin();
        let column_types = self.describe_columns(cursor, &mut row_buffer, plugin.as_deref())?;

        // Per-cell loop required: caller hands us `&mut C` because the
        // multi-result path needs to keep operating on the statement after
        // we drain this cursor. `BlockCursor::bind_buffer` would consume
        // it, breaking that contract.
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

        // FOR JSON normalisation — see execute_query_inner above (closes #2).
        coalesce_for_json_rows(&mut row_buffer);

        encode_query_result_payload(&row_buffer, self.use_columnar, self.use_compression)
    }

    pub(super) fn describe_columns<C: ResultSetMetadata>(
        &self,
        cursor: &mut C,
        row_buffer: &mut RowBuffer,
        plugin: Option<&dyn DriverPlugin>,
    ) -> Result<Vec<OdbcType>> {
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
            let odbc_type = self.map_sql_type(sql_type_code, plugin);
            row_buffer.add_column(col_name.to_string(), odbc_type);
            column_types.push(odbc_type);
        }

        Ok(column_types)
    }
}

use super::ExecutionEngine;
use crate::engine::cell_reader::CellReader;
use crate::engine::query::ResultEncoding;
use crate::engine::sqlserver_json::coalesce_for_json_rows;
use crate::error::{OdbcError, Result};
use crate::plugins::DriverPlugin;
use crate::protocol::{
    row_buffer_to_columnar, ColumnarEncoder, OdbcType, RowBuffer, RowBufferEncoder,
};
use odbc_api::{Cursor, ResultSetMetadata};

/// Resolve the effective ODBC block-fetch batch size: per-query override when
/// provided, otherwise the process-wide default from `configured_batch_size`.
pub(crate) fn resolve_batch_size(fetch_size: Option<u32>) -> usize {
    fetch_size
        .map(|n| n.max(1) as usize)
        .unwrap_or_else(crate::engine::core::block_fetch::configured_batch_size)
}

/// Shared cursor drain + encode used by [`CachedConnection`] and
/// [`ExecutionEngine`]. When `plugin` is `None`, column types are mapped via
/// [`OdbcType::from_odbc_sql_type`] (no driver-plugin overrides).
pub(crate) fn encode_optional_cursor_with_encoding<C>(
    cursor: Option<C>,
    encoding: ResultEncoding,
    plugin: Option<&dyn DriverPlugin>,
    fetch_size: Option<u32>,
) -> Result<Vec<u8>>
where
    C: Cursor + ResultSetMetadata,
{
    let use_columnar = encoding.use_columnar();
    let use_compression = encoding.use_compression();
    let batch_size = resolve_batch_size(fetch_size);

    let mut row_buffer = RowBuffer::new();

    let Some(mut cursor) = cursor else {
        return encode_query_result_payload(row_buffer, use_columnar, use_compression);
    };

    let (column_types, buffer_descs) = crate::engine::core::block_fetch::describe_and_plan_columns(
        &mut cursor,
        &mut row_buffer,
        plugin,
    )?;

    #[cfg(feature = "block-cursor-fetch")]
    {
        if use_columnar && !crate::engine::sqlserver_json::is_for_json_result(&row_buffer) {
            if let Some(descs) = buffer_descs {
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
                    batch_size,
                )?;
                return ColumnarEncoder::encode(&v2, use_compression);
            }
        }
    }

    let _drained = crate::engine::fetch::fetch_cursor_into_row_buffer(
        cursor,
        &column_types,
        &mut row_buffer,
        batch_size,
        buffer_descs,
    )?;

    coalesce_for_json_rows(&mut row_buffer);

    encode_query_result_payload(row_buffer, use_columnar, use_compression)
}

fn describe_columns_for_encode<C: ResultSetMetadata>(
    cursor: &mut C,
    row_buffer: &mut RowBuffer,
    plugin: Option<&dyn DriverPlugin>,
) -> Result<Vec<OdbcType>> {
    let (column_types, _) =
        crate::engine::core::block_fetch::describe_and_plan_columns(cursor, row_buffer, plugin)?;
    Ok(column_types)
}

/// Encodes a row buffer for query / optional-cursor paths (row-major or columnar).
pub(crate) fn encode_query_result_payload(
    row_buffer: RowBuffer,
    use_columnar: bool,
    use_compression: bool,
) -> Result<Vec<u8>> {
    if use_columnar {
        let columnar_buffer = row_buffer_to_columnar(row_buffer)?;
        ColumnarEncoder::encode(&columnar_buffer, use_compression)
    } else {
        RowBufferEncoder::encode_result(&row_buffer)
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
        let encoding = if self.use_columnar {
            if self.use_compression {
                ResultEncoding::ColumnarCompressed
            } else {
                ResultEncoding::Columnar
            }
        } else {
            ResultEncoding::RowMajor
        };
        encode_optional_cursor_with_encoding(cursor, encoding, plugin, None)
    }

    pub(super) fn encode_optional_cursor_with_fetch_size<C>(
        &self,
        cursor: Option<C>,
        plugin: Option<&dyn DriverPlugin>,
        fetch_size: Option<u32>,
    ) -> Result<Vec<u8>>
    where
        C: Cursor + ResultSetMetadata,
    {
        let encoding = if self.use_columnar {
            if self.use_compression {
                ResultEncoding::ColumnarCompressed
            } else {
                ResultEncoding::Columnar
            }
        } else {
            ResultEncoding::RowMajor
        };
        encode_optional_cursor_with_encoding(cursor, encoding, plugin, fetch_size)
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

    /// Same as [`Self::encode_cursor`], but consumes `cursor` so block-fetch
    /// and direct columnar paths can bind a `ColumnarAnyBuffer`. Returns the
    /// unbound cursor for callers that must call `into_stmt()` before
    /// `SQLMoreResults` (multi-result buffered collect).
    pub(super) fn encode_cursor_owned<C: Cursor + ResultSetMetadata>(
        &self,
        cursor: C,
    ) -> Result<(Vec<u8>, C)> {
        let mut row_buffer = RowBuffer::new();
        let plugin = self.current_plugin();
        let mut cursor = cursor;
        let column_types =
            self.describe_columns(&mut cursor, &mut row_buffer, plugin.as_deref())?;

        #[cfg(feature = "block-cursor-fetch")]
        {
            if self.use_columnar && !crate::engine::sqlserver_json::is_for_json_result(&row_buffer)
            {
                if let Some(descs) =
                    crate::engine::core::block_fetch::plan_buffer_descs(&mut cursor, &column_types)?
                {
                    let column_metas: Vec<crate::protocol::columnar::ColumnMetadata> =
                        std::mem::take(&mut row_buffer.columns)
                            .into_iter()
                            .map(|c| crate::protocol::columnar::ColumnMetadata {
                                name: c.name,
                                odbc_type: c.odbc_type,
                            })
                            .collect();
                    let (cursor, v2) = crate::engine::core::columnar_fetch::fetch_columnar_into(
                        cursor,
                        column_metas,
                        &column_types,
                        descs,
                        crate::engine::core::block_fetch::configured_batch_size(),
                    )?;
                    let encoded =
                        crate::protocol::ColumnarEncoder::encode(&v2, self.use_compression)?;
                    return Ok((encoded, cursor));
                }
            }
        }

        let cursor = crate::engine::fetch::fetch_cursor_into_row_buffer(
            cursor,
            &column_types,
            &mut row_buffer,
            resolve_batch_size(None),
            None,
        )?;

        coalesce_for_json_rows(&mut row_buffer);

        Ok((
            encode_query_result_payload(row_buffer, self.use_columnar, self.use_compression)?,
            cursor,
        ))
    }

    pub(super) fn describe_columns<C: ResultSetMetadata>(
        &self,
        cursor: &mut C,
        row_buffer: &mut RowBuffer,
        plugin: Option<&dyn DriverPlugin>,
    ) -> Result<Vec<OdbcType>> {
        describe_columns_for_encode(cursor, row_buffer, plugin)
    }
}

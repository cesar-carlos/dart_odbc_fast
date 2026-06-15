use crate::engine::core::execution::result_encoding::encode_query_result_payload;
use crate::engine::query::ResultEncoding;
use crate::error::{OdbcError, Result};
use crate::protocol::{OdbcType, RowBuffer, RowBufferEncoder};
use odbc_api::ResultSetMetadata;

pub(super) fn describe_streaming_columns<C>(
    cursor: &mut C,
    row_buffer: &mut RowBuffer,
) -> Result<Vec<OdbcType>>
where
    C: ResultSetMetadata,
{
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
    Ok(column_types)
}

/// Encodes a fetch batch using the requested wire layout (v4.2 streaming).
pub(crate) fn encode_row_buffer_with_encoding(
    row_buffer: &mut RowBuffer,
    encoding: ResultEncoding,
) -> Result<Vec<u8>> {
    match encoding {
        ResultEncoding::RowMajor => RowBufferEncoder::encode_result(row_buffer),
        ResultEncoding::Columnar | ResultEncoding::ColumnarCompressed => {
            let rows = std::mem::take(&mut row_buffer.rows);
            let batch = RowBuffer {
                columns: row_buffer.columns.clone(),
                rows,
            };
            encode_query_result_payload(
                batch,
                true,
                matches!(encoding, ResultEncoding::ColumnarCompressed),
            )
        }
    }
}

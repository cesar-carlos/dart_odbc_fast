use crate::engine::query::ResultEncoding;
use crate::error::{OdbcError, Result};
use crate::protocol::columnar::RowBufferV2;
use crate::protocol::columnar_encoder::ColumnarCompressionWorkspace;
use crate::protocol::converter::{empty_columnar_for_row_buffer, transpose_row_buffer_into};
use crate::protocol::{
    row_buffer_to_columnar, ColumnarEncoder, OdbcType, RowBuffer, RowBufferEncoder,
};
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
    let mut output = Vec::new();
    encode_row_buffer_with_encoding_into(row_buffer, encoding, &mut output)?;
    Ok(output)
}

/// Appends a fetch batch to an existing output allocation. This is used by
/// MULT streaming after it reserves the frame prefix.
pub(crate) fn encode_row_buffer_with_encoding_into(
    row_buffer: &mut RowBuffer,
    encoding: ResultEncoding,
    output: &mut Vec<u8>,
) -> Result<()> {
    match encoding {
        ResultEncoding::RowMajor => RowBufferEncoder::encode_result_into(row_buffer, output),
        ResultEncoding::Columnar | ResultEncoding::ColumnarCompressed => {
            let rows = std::mem::take(&mut row_buffer.rows);
            let batch = RowBuffer {
                columns: row_buffer.columns.clone(),
                rows,
            };
            let columnar = row_buffer_to_columnar(batch)?;
            ColumnarEncoder::encode_into(
                output,
                &columnar,
                matches!(encoding, ResultEncoding::ColumnarCompressed),
            )
        }
    }
}

pub(super) struct FallbackColumnarEncoder {
    batch: RowBufferV2,
    workspace: ColumnarCompressionWorkspace,
}

impl FallbackColumnarEncoder {
    pub(super) fn new(row_buffer: &RowBuffer) -> Self {
        Self {
            batch: empty_columnar_for_row_buffer(row_buffer),
            workspace: ColumnarCompressionWorkspace::new(),
        }
    }

    pub(super) fn encode_into(
        &mut self,
        row_buffer: &mut RowBuffer,
        compressed: bool,
        output: &mut Vec<u8>,
    ) -> Result<()> {
        transpose_row_buffer_into(row_buffer, &mut self.batch)?;
        ColumnarEncoder::encode_into_with_workspace(
            output,
            &self.batch,
            compressed,
            &mut self.workspace,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fallback_reuses_metadata_and_matches_standalone_batches() {
        let mut rows = RowBuffer::new();
        rows.add_column("payload".to_string(), OdbcType::Binary);
        let mut encoder = FallbackColumnarEncoder::new(&rows);
        let name_ptr = encoder.batch.columns[0].metadata.name.as_ptr();
        for len in [2048, 3072, 0] {
            rows.rows.clear();
            if len > 0 {
                rows.add_row_vecs(vec![Some(vec![42; len])]);
                rows.add_row_vecs(vec![None]);
            }
            for compressed in [false, true] {
                let mut expected_rows = rows.clone();
                let expected = encode_row_buffer_with_encoding(
                    &mut expected_rows,
                    if compressed {
                        ResultEncoding::ColumnarCompressed
                    } else {
                        ResultEncoding::Columnar
                    },
                )
                .expect("standalone encode");
                let mut actual_rows = rows.clone();
                let mut actual = Vec::new();
                encoder
                    .encode_into(&mut actual_rows, compressed, &mut actual)
                    .expect("fallback encode");
                assert_eq!(actual, expected);
                assert_eq!(encoder.batch.columns[0].metadata.name.as_ptr(), name_ptr);
            }
        }
    }
}

use crate::error::{OdbcError, Result};
use crate::protocol::{BulkColumnData, BulkColumnType, BulkInsertPayload};

use super::bound_column::BoundColumnRef;

pub(crate) fn build_bound_columns<'a>(
    payload: &'a BulkInsertPayload,
) -> Result<Vec<BoundColumnRef<'a>>> {
    if payload.column_data.len() != payload.columns.len() {
        return Err(OdbcError::ValidationError(format!(
            "Native BCP payload mismatch: {} columns vs {} data blocks",
            payload.columns.len(),
            payload.column_data.len()
        )));
    }

    payload
        .columns
        .iter()
        .zip(payload.column_data.iter())
        .map(|(spec, data)| match (&spec.col_type, data) {
            (
                BulkColumnType::I32,
                BulkColumnData::I32 {
                    values,
                    null_bitmap,
                },
            ) => Ok(BoundColumnRef::I32 {
                values: values.as_slice(),
                null_bitmap: validate_null_bitmap(
                    null_bitmap.as_deref(),
                    values.len(),
                    spec.name.as_str(),
                )?,
                cell: std::mem::MaybeUninit::uninit(),
            }),
            (
                BulkColumnType::I64,
                BulkColumnData::I64 {
                    values,
                    null_bitmap,
                },
            ) => Ok(BoundColumnRef::I64 {
                values: values.as_slice(),
                null_bitmap: validate_null_bitmap(
                    null_bitmap.as_deref(),
                    values.len(),
                    spec.name.as_str(),
                )?,
                cell: std::mem::MaybeUninit::uninit(),
            }),
            (
                BulkColumnType::Text,
                BulkColumnData::Text {
                    rows,
                    max_len,
                    null_bitmap,
                },
            ) => {
                let max_cell_len = if spec.max_len > 0 {
                    spec.max_len
                } else {
                    *max_len
                };
                if max_cell_len == 0 {
                    return Err(OdbcError::ValidationError(format!(
                        "Native BCP Text column '{}' requires a positive max_len",
                        spec.name
                    )));
                }
                Ok(BoundColumnRef::Text {
                    rows: rows.as_slice(),
                    max_cell_len,
                    null_bitmap: validate_null_bitmap(
                        null_bitmap.as_deref(),
                        rows.len(),
                        spec.name.as_str(),
                    )?,
                    cell: vec![0u8; max_cell_len],
                })
            }
            (BulkColumnType::I32 | BulkColumnType::I64 | BulkColumnType::Text, _) => {
                Err(OdbcError::UnsupportedFeature(format!(
                    "Native BCP currently requires matching payload type for '{}'",
                    spec.name
                )))
            }
            _ => Err(OdbcError::UnsupportedFeature(format!(
                "Native BCP currently supports I32, I64, and Text columns; '{}' uses {:?}",
                spec.name, spec.col_type
            ))),
        })
        .collect()
}

fn validate_null_bitmap<'a>(
    bitmap: Option<&'a [u8]>,
    row_count: usize,
    column_name: &str,
) -> Result<Option<&'a [u8]>> {
    let Some(bitmap) = bitmap else {
        return Ok(None);
    };
    let expected = row_count.div_ceil(8);
    if bitmap.len() != expected {
        return Err(OdbcError::ValidationError(format!(
            "Native BCP null bitmap size mismatch for column '{}': got {}, expected {}",
            column_name,
            bitmap.len(),
            expected
        )));
    }
    Ok(Some(bitmap))
}

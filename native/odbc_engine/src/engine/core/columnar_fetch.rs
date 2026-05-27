//! Direct-to-`RowBufferV2` fetch (gated by `block-cursor-fetch`).
//!
//! Sprint 2 of the engine-perf plan. Avoids the two-pass cost of the
//! columnar encoding path:
//!
//! 1. Today: cursor → `RowBuffer` (row-major, every cell as
//!    `Vec<u8>`) → `row_buffer_to_columnar` → `ColumnarEncoder::encode`.
//!    The transposition `.clone()`s every Binary/Varchar cell, so the
//!    full result set is materialised in memory twice.
//! 2. Here: cursor → `ColumnarAnyBuffer` → `RowBufferV2` directly. The
//!    column views from `odbc-api` are copied into the typed
//!    `ColumnData` variants once; no row-major intermediate exists.
//!
//! When any column would force a fallback (LOB, unbounded text), the
//! caller is expected to fall back to the row-major + transpose path
//! exactly as before. The decision uses the **same** [`plan_buffer_descs`]
//! helper as [`crate::engine::core::block_fetch`] so both fast paths
//! agree on what is bindable.

use crate::error::{OdbcError, Result};
use crate::protocol::columnar::{ColumnData, ColumnMetadata, RowBufferV2};
use crate::protocol::OdbcType;
use odbc_api::buffers::{AnySlice, BufferDesc, ColumnarAnyBuffer};
use odbc_api::Cursor;

use super::block_fetch::DEFAULT_BATCH_SIZE;

/// Bind `cursor` to a `ColumnarAnyBuffer` and accumulate every batch into
/// a freshly-built `RowBufferV2` (column-major). Returns the unbound
/// cursor so multi-result paths can still call `into_stmt()`.
///
/// Caller responsibilities:
///
/// - Provide `column_metas`/`column_types` already inspected via
///   `ExecutionEngine::describe_columns` (or equivalent) so the wire
///   metadata stays consistent.
/// - Provide `buffer_descs` planned via
///   [`crate::engine::core::block_fetch::plan_buffer_descs`]. If that
///   helper returned `None`, the caller must fall back to the row-major
///   path — do not invoke this function.
pub fn fetch_columnar_into<C>(
    cursor: C,
    column_metas: Vec<ColumnMetadata>,
    column_types: &[OdbcType],
    buffer_descs: Vec<BufferDesc>,
    batch_size: usize,
) -> Result<(C, RowBufferV2)>
where
    C: Cursor,
{
    debug_assert_eq!(column_metas.len(), column_types.len());
    debug_assert_eq!(column_metas.len(), buffer_descs.len());

    let batch_size = batch_size.max(1);
    let buffer = ColumnarAnyBuffer::try_from_descs(batch_size, buffer_descs).map_err(|e| {
        OdbcError::InternalError(format!("ColumnarAnyBuffer allocation failed: {e}"))
    })?;
    let mut block_cursor = cursor.bind_buffer(buffer).map_err(OdbcError::from)?;

    let mut accumulators: Vec<ColumnAccumulator> = column_types
        .iter()
        .copied()
        .map(ColumnAccumulator::new)
        .collect();

    let mut total_rows: usize = 0;

    while let Some(batch) = block_cursor
        .fetch_with_truncation_check(true)
        .map_err(OdbcError::from)?
    {
        let batch_rows = batch.num_rows();
        if batch_rows == 0 {
            continue;
        }
        total_rows = total_rows
            .checked_add(batch_rows)
            .ok_or_else(|| OdbcError::ResourceLimitReached("row count overflow".to_string()))?;

        for (col_idx, accumulator) in accumulators.iter_mut().enumerate() {
            accumulator.append_from_slice(batch.column(col_idx), col_idx)?;
        }
    }

    let (cursor, _buffer) = block_cursor.unbind().map_err(OdbcError::from)?;

    let mut v2 = RowBufferV2::with_capacity(column_metas.len());
    v2.set_row_count(total_rows);
    // `ColumnMetadata` is intentionally non-`Clone` (its `name: String`
    // can be large); the caller hands ownership over to us so each column
    // moves into `v2` exactly once with zero allocations.
    for (meta, accumulator) in column_metas.into_iter().zip(accumulators.into_iter()) {
        v2.add_column(meta, accumulator.into_column_data());
    }

    Ok((cursor, v2))
}

/// Per-column accumulator typed by the destination `ColumnData` variant.
enum ColumnAccumulator {
    Integer(Vec<Option<i32>>),
    BigInt(Vec<Option<i64>>),
    Varchar(Vec<Option<Vec<u8>>>),
    Binary(Vec<Option<Vec<u8>>>),
}

impl ColumnAccumulator {
    fn new(odbc_type: OdbcType) -> Self {
        match odbc_type {
            OdbcType::Integer => Self::Integer(Vec::new()),
            OdbcType::BigInt => Self::BigInt(Vec::new()),
            OdbcType::Binary => Self::Binary(Vec::new()),
            _ => Self::Varchar(Vec::new()),
        }
    }

    fn append_from_slice(&mut self, slice: AnySlice<'_>, col_idx: usize) -> Result<()> {
        match self {
            Self::Integer(values) => {
                let view = slice.as_nullable_slice::<i32>().ok_or_else(|| {
                    OdbcError::InternalError(format!(
                        "Columnar fetch: column {col_idx} expected nullable i32 slice"
                    ))
                })?;
                values.reserve(view.len());
                for cell in view.into_iter() {
                    values.push(cell.copied());
                }
            }
            Self::BigInt(values) => {
                let view = slice.as_nullable_slice::<i64>().ok_or_else(|| {
                    OdbcError::InternalError(format!(
                        "Columnar fetch: column {col_idx} expected nullable i64 slice"
                    ))
                })?;
                values.reserve(view.len());
                for cell in view.into_iter() {
                    values.push(cell.copied());
                }
            }
            Self::Varchar(values) => {
                let view = slice.as_w_text_view().ok_or_else(|| {
                    OdbcError::InternalError(format!(
                        "Columnar fetch: column {col_idx} expected wide text view"
                    ))
                })?;
                for cell in view.iter() {
                    match cell {
                        Some(wide) => {
                            // Match the legacy CellReader behaviour: UTF-16
                            // → UTF-8 with U+FFFD replacement for unpaired
                            // surrogates.
                            let bytes = String::from_utf16_lossy(wide.as_slice()).into_bytes();
                            values.push(Some(bytes));
                        }
                        None => values.push(None),
                    }
                }
            }
            Self::Binary(values) => {
                let view = slice.as_bin_view().ok_or_else(|| {
                    OdbcError::InternalError(format!(
                        "Columnar fetch: column {col_idx} expected binary view"
                    ))
                })?;
                for cell in view.iter() {
                    match cell {
                        Some(bytes) => values.push(Some(bytes.to_vec())),
                        None => values.push(None),
                    }
                }
            }
        }
        Ok(())
    }

    fn into_column_data(self) -> ColumnData {
        match self {
            Self::Integer(v) => ColumnData::Integer(v),
            Self::BigInt(v) => ColumnData::BigInt(v),
            Self::Varchar(v) => ColumnData::Varchar(v),
            Self::Binary(v) => ColumnData::Binary(v),
        }
    }
}

/// Convenience re-export so call sites only import a single constant.
#[deprecated(
    note = "Use `block_fetch::configured_batch_size()` to honour ODBC_FAST_BLOCK_FETCH_BATCH"
)]
pub const COLUMNAR_DEFAULT_BATCH_SIZE: usize = DEFAULT_BATCH_SIZE;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::columnar::RowBufferV2;

    #[test]
    fn column_accumulator_integer_collects_options_in_order() {
        let mut acc = ColumnAccumulator::new(OdbcType::Integer);
        // Drive the accumulator manually because we can't easily synthesise
        // an `AnySlice` without a real ODBC fetch. The append path is
        // covered by the regression suite under `cargo test --features
        // block-cursor-fetch`, which exercises the full BlockCursor pipe.
        match &mut acc {
            ColumnAccumulator::Integer(v) => {
                v.push(Some(1));
                v.push(None);
                v.push(Some(2));
            }
            _ => panic!("expected Integer accumulator"),
        }
        match acc.into_column_data() {
            ColumnData::Integer(v) => assert_eq!(v, vec![Some(1), None, Some(2)]),
            _ => panic!("expected Integer column data"),
        }
    }

    #[test]
    fn column_accumulator_dispatches_by_odbc_type() {
        for (t, expected_variant) in [
            (OdbcType::Integer, "Integer"),
            (OdbcType::BigInt, "BigInt"),
            (OdbcType::Binary, "Binary"),
            (OdbcType::Varchar, "Varchar"),
            (OdbcType::NVarchar, "Varchar"),
            (OdbcType::Decimal, "Varchar"),
            (OdbcType::Date, "Varchar"),
            (OdbcType::Timestamp, "Varchar"),
        ] {
            let variant = match ColumnAccumulator::new(t).into_column_data() {
                ColumnData::Integer(_) => "Integer",
                ColumnData::BigInt(_) => "BigInt",
                ColumnData::Binary(_) => "Binary",
                ColumnData::Varchar(_) => "Varchar",
            };
            assert_eq!(variant, expected_variant, "OdbcType={t:?}");
        }
    }

    #[test]
    fn column_accumulator_into_column_data_preserves_data_for_varchar() {
        let mut acc = ColumnAccumulator::new(OdbcType::Varchar);
        match &mut acc {
            ColumnAccumulator::Varchar(v) => {
                v.push(Some(b"alpha".to_vec()));
                v.push(None);
                v.push(Some(b"beta".to_vec()));
            }
            _ => unreachable!(),
        }
        match acc.into_column_data() {
            ColumnData::Varchar(v) => {
                assert_eq!(v.len(), 3);
                assert_eq!(v[0].as_deref(), Some(b"alpha".as_ref()));
                assert!(v[1].is_none());
                assert_eq!(v[2].as_deref(), Some(b"beta".as_ref()));
            }
            _ => panic!("expected Varchar"),
        }
    }

    #[test]
    fn rowbufferv2_capacity_helper_matches_columnar_fetch_assumption() {
        // Smoke check: `with_capacity` must yield an empty buffer ready
        // to receive columns. If this invariant ever changes the
        // `fetch_columnar_into` initialisation needs to follow.
        let v2 = RowBufferV2::with_capacity(3);
        assert_eq!(v2.column_count(), 0);
        assert_eq!(v2.row_count, 0);
    }
}

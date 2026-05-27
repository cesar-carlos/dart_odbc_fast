//! Shared cursor → row-buffer fetch dispatcher.
//!
//! Centralises the choice between the per-cell legacy path
//! (`cursor.next_row()` + [`crate::engine::cell_reader::CellReader`]) and
//! the block-cursor path (gated by the `block-cursor-fetch` feature, see
//! [`crate::engine::core::block_fetch`]).
//!
//! Every call site that previously inlined a `while let Some(mut row) =
//! cursor.next_row() { ... }` loop is rewritten to call
//! [`fetch_cursor_into_row_buffer`] with the already-described
//! `column_types`. When the feature is off the function is a thin wrapper
//! around the legacy loop, so behaviour is unchanged for callers that opt
//! out.

use crate::engine::cell_reader::CellReader;
use crate::error::{OdbcError, Result};
use crate::protocol::{OdbcType, RowBuffer};
use odbc_api::Cursor;

#[cfg(feature = "block-cursor-fetch")]
use crate::engine::core::block_fetch;
#[cfg(feature = "block-cursor-fetch")]
use odbc_api::ResultSetMetadata;

/// Drain `cursor` into `row_buffer` using the fastest path that is safe for
/// the cursor's schema.
///
/// With `block-cursor-fetch` on, the cursor is bound to a
/// `ColumnarAnyBuffer` and drained in batches. If any column would require
/// an unbounded inline allocation (LOBs, MAX-typed columns without an
/// advertised length) the helper transparently falls back to the legacy
/// per-row path — no truncation, no data loss.
///
/// Returns the cursor after the drain so the caller can choose between
/// `cursor.into_stmt()` (preserves pending result sets for
/// `SQLMoreResults`) and dropping it (calls `SQLCloseCursor`).
pub(crate) fn fetch_cursor_into_row_buffer<C>(
    #[cfg_attr(not(feature = "block-cursor-fetch"), allow(unused_mut))] mut cursor: C,
    column_types: &[OdbcType],
    row_buffer: &mut RowBuffer,
) -> Result<C>
where
    C: Cursor,
{
    #[cfg(feature = "block-cursor-fetch")]
    {
        // ResultSetMetadata is required by `block_fetch::plan_buffer_descs`
        // but `Cursor` already implies it via its supertrait bound; the
        // import above guards the binding at the type level.
        fn _assert_metadata<T: ResultSetMetadata>() {}
        _assert_metadata::<C>();

        if let Some(descs) = block_fetch::plan_buffer_descs(&mut cursor, column_types)? {
            return block_fetch::fetch_rows_into(
                cursor,
                column_types,
                descs,
                block_fetch::configured_batch_size(),
                row_buffer,
            );
        }
    }
    legacy_fetch_loop(cursor, column_types, row_buffer)
}

fn legacy_fetch_loop<C>(
    mut cursor: C,
    column_types: &[OdbcType],
    row_buffer: &mut RowBuffer,
) -> Result<C>
where
    C: Cursor,
{
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
    Ok(cursor)
}

/// Batched streaming variant. Fills `row_buffer.rows` (preserving its
/// existing capacity) with up to `batch_size` rows from `cursor`, returning
/// `(cursor, fetched)` so the caller can decide whether to keep iterating.
///
/// This deliberately stays on the per-cell path even when
/// `block-cursor-fetch` is enabled: streaming callers already control the
/// batch size externally and rebinding a `ColumnarAnyBuffer` per batch
/// would amortise nothing. The block-cursor path is reserved for the
/// "fetch everything into one buffer and encode" call sites.
pub(crate) fn fetch_batch_into_row_buffer<C>(
    cursor: &mut C,
    column_types: &[OdbcType],
    batch_size: usize,
    row_buffer: &mut RowBuffer,
) -> Result<usize>
where
    C: Cursor,
{
    let mut cell_reader = CellReader::new();
    let mut fetched = 0;
    while fetched < batch_size {
        let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? else {
            break;
        };
        let mut row_data = Vec::with_capacity(column_types.len());
        for (col_idx, &odbc_type) in column_types.iter().enumerate() {
            let col_number: u16 = (col_idx + 1)
                .try_into()
                .map_err(|_| OdbcError::InternalError("Invalid column number".to_string()))?;
            let cell_data = cell_reader.read_cell_bytes(&mut row, col_number, odbc_type)?;
            row_data.push(cell_data);
        }
        row_buffer.add_row(row_data);
        fetched += 1;
    }
    Ok(fetched)
}

//! Long-lived `BlockCursor` sessions for batched streaming fetch.
//!
//! Binds the cursor once (when [`super::plan_buffer_descs`] succeeds) and
//! drains it in fetch-sized ODBC batches. Avoids per-cell `SQLGetData` and
//! per-batch buffer rebind overhead.

use super::column_buffers::append_batch_to_row_buffer_with_reuse;
use crate::error::{OdbcError, Result};
use crate::protocol::{CellBytes, OdbcType, RowBuffer};
use odbc_api::buffers::{BufferDesc, ColumnarAnyBuffer};
use odbc_api::Cursor;

/// Row-major block fetch session for streaming callers.
pub(crate) struct RowMajorBlockSession<C: Cursor> {
    block_cursor: odbc_api::BlockCursor<C, ColumnarAnyBuffer>,
    column_types: Vec<OdbcType>,
    recycled_rows: Vec<Vec<Option<CellBytes>>>,
    batch_size: usize,
    exhausted: bool,
}

impl<C: Cursor> RowMajorBlockSession<C> {
    pub(crate) fn try_begin(
        cursor: C,
        column_types: Vec<OdbcType>,
        buffer_descs: Vec<BufferDesc>,
        batch_size: usize,
    ) -> Result<Self> {
        let batch_size = batch_size.max(1);
        let buffer = ColumnarAnyBuffer::try_from_descs(batch_size, buffer_descs).map_err(|e| {
            OdbcError::InternalError(format!("ColumnarAnyBuffer allocation failed: {e}"))
        })?;
        let block_cursor = cursor.bind_buffer(buffer).map_err(OdbcError::from)?;
        Ok(Self {
            block_cursor,
            column_types,
            recycled_rows: Vec::new(),
            batch_size,
            exhausted: false,
        })
    }

    /// Fetches up to one ODBC batch (bounded by the session's buffer size)
    /// into `row_buffer`, clearing any prior rows first.
    pub(crate) fn fetch_next_batch(&mut self, row_buffer: &mut RowBuffer) -> Result<usize> {
        recycle_rows(row_buffer, &mut self.recycled_rows, self.batch_size);
        if self.exhausted {
            return Ok(0);
        }

        let Some(batch) = self
            .block_cursor
            .fetch_with_truncation_check(true)
            .map_err(OdbcError::from)?
        else {
            self.exhausted = true;
            return Ok(0);
        };

        let batch_rows = batch.num_rows();
        if batch_rows == 0 {
            self.exhausted = true;
            return Ok(0);
        }

        append_batch_to_row_buffer_with_reuse(
            batch,
            &self.column_types,
            row_buffer,
            &mut self.recycled_rows,
        )?;
        Ok(batch_rows)
    }

    pub(crate) fn into_cursor(self) -> Result<C> {
        let (cursor, _buffer) = self.block_cursor.unbind().map_err(OdbcError::from)?;
        Ok(cursor)
    }
}

fn recycle_rows(
    row_buffer: &mut RowBuffer,
    recycled_rows: &mut Vec<Vec<Option<CellBytes>>>,
    batch_size: usize,
) {
    for mut row in row_buffer.rows.drain(..) {
        row.clear();
        if recycled_rows.len() < batch_size {
            recycled_rows.push(row);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recycled_rows_retain_vectors_but_not_cells_and_are_bounded() {
        let mut rows = RowBuffer::new();
        rows.rows
            .push(vec![Some(CellBytes::from(&b"text"[..])), None]);
        rows.rows
            .push(vec![None, Some(CellBytes::from(&b"binary"[..]))]);
        rows.rows.push(vec![None]);
        let pointers: Vec<_> = rows.rows.iter().take(2).map(Vec::as_ptr).collect();
        let mut recycled = Vec::new();
        recycle_rows(&mut rows, &mut recycled, 2);
        assert!(rows.rows.is_empty());
        assert_eq!(recycled.len(), 2);
        assert!(recycled.iter().all(Vec::is_empty));
        assert!(recycled.iter().all(|row| pointers.contains(&row.as_ptr())));
    }
}

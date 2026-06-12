use crate::protocol::bulk_insert::{is_null, BulkCellBytes};

pub(crate) const SQLINT4: i32 = 56;
pub(crate) const SQLINT8: i32 = 127;
/// ANSI character / varchar bulk type (`sqlncli.h`).
pub(crate) const SQLCHARACTER: i32 = 47;
pub(crate) const SQL_NULL_DATA: i32 = -1;

pub(crate) enum BoundColumnRef<'a> {
    I32 {
        values: &'a [i32],
        null_bitmap: Option<&'a [u8]>,
        cell: std::mem::MaybeUninit<i32>,
    },
    I64 {
        values: &'a [i64],
        null_bitmap: Option<&'a [u8]>,
        cell: std::mem::MaybeUninit<i64>,
    },
    Text {
        rows: &'a [BulkCellBytes],
        max_cell_len: usize,
        null_bitmap: Option<&'a [u8]>,
        cell: Vec<u8>,
    },
}

impl<'a> BoundColumnRef<'a> {
    pub(crate) fn len(&self) -> usize {
        match self {
            BoundColumnRef::I32 { values, .. } => values.len(),
            BoundColumnRef::I64 { values, .. } => values.len(),
            BoundColumnRef::Text { rows, .. } => rows.len(),
        }
    }

    pub(crate) fn bind_args_mut(&mut self) -> (*const u8, i32, i32) {
        match self {
            BoundColumnRef::I32 { cell, .. } => (
                cell.as_mut_ptr().cast::<u8>(),
                std::mem::size_of::<i32>() as i32,
                SQLINT4,
            ),
            BoundColumnRef::I64 { cell, .. } => (
                cell.as_mut_ptr().cast::<u8>(),
                std::mem::size_of::<i64>() as i32,
                SQLINT8,
            ),
            BoundColumnRef::Text { cell, max_cell_len, .. } => (
                cell.as_ptr(),
                i32::try_from(*max_cell_len).unwrap_or(i32::MAX),
                SQLCHARACTER,
            ),
        }
    }

    pub(crate) fn write_row(&mut self, row_idx: usize) {
        match self {
            BoundColumnRef::I32 {
                values,
                null_bitmap,
                cell,
            } => {
                let value = if null_bitmap.is_some_and(|bm| is_null(bm, row_idx)) {
                    0
                } else {
                    values[row_idx]
                };
                let _ = cell.write(value);
            }
            BoundColumnRef::I64 {
                values,
                null_bitmap,
                cell,
            } => {
                let value = if null_bitmap.is_some_and(|bm| is_null(bm, row_idx)) {
                    0
                } else {
                    values[row_idx]
                };
                let _ = cell.write(value);
            }
            BoundColumnRef::Text {
                rows,
                max_cell_len,
                null_bitmap,
                cell,
            } => {
                cell.fill(0);
                if null_bitmap.is_some_and(|bm| is_null(bm, row_idx)) {
                    return;
                }
                let row = rows[row_idx].as_slice();
                let n = row.len().min(*max_cell_len);
                cell[..n].copy_from_slice(&row[..n]);
            }
        }
    }

    pub(crate) fn row_collen_for_bcp(&self, row_idx: usize) -> i32 {
        match self {
            BoundColumnRef::I32 { null_bitmap, .. } => {
                if null_bitmap.is_some_and(|bm| is_null(bm, row_idx)) {
                    SQL_NULL_DATA
                } else {
                    std::mem::size_of::<i32>() as i32
                }
            }
            BoundColumnRef::I64 { null_bitmap, .. } => {
                if null_bitmap.is_some_and(|bm| is_null(bm, row_idx)) {
                    SQL_NULL_DATA
                } else {
                    std::mem::size_of::<i64>() as i32
                }
            }
            BoundColumnRef::Text {
                rows,
                null_bitmap,
                ..
            } => {
                if null_bitmap.is_some_and(|bm| is_null(bm, row_idx)) {
                    SQL_NULL_DATA
                } else {
                    i32::try_from(rows[row_idx].len()).unwrap_or(i32::MAX)
                }
            }
        }
    }
}

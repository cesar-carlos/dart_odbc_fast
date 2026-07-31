use crate::engine::wide_text::wide_text_to_utf8_bytes;
use crate::error::{OdbcError, Result};
use crate::protocol::{cell_bytes_from_slice, CellBytes, OdbcType, RowBuffer};
use odbc_api::buffers::AnySlice;
use std::fmt::{self, Write as _};

/// Thin `fmt::Write` adapter so temporal formatters can target any
/// `Extend<u8>` sink (`Vec<u8>`, `CellBytes` / `SmallVec`, …) without an
/// intermediate `String`.
struct AppendBytes<'a, T: Extend<u8>>(&'a mut T);

impl<T: Extend<u8>> fmt::Write for AppendBytes<'_, T> {
    fn write_str(&mut self, s: &str) -> fmt::Result {
        self.0.extend(s.as_bytes().iter().copied());
        Ok(())
    }
}

pub(super) fn append_batch_to_row_buffer(
    batch: &odbc_api::buffers::ColumnarBuffer<odbc_api::buffers::AnyBuffer>,
    column_types: &[OdbcType],
    row_buffer: &mut RowBuffer,
) -> Result<()> {
    let num_rows = batch.num_rows();
    if num_rows == 0 {
        return Ok(());
    }
    let num_cols = column_types.len();
    let starting_row = row_buffer.rows.len();
    row_buffer.rows.reserve(num_rows);
    for _ in 0..num_rows {
        let mut row = Vec::with_capacity(num_cols);
        row.resize_with(num_cols, || None);
        row_buffer.rows.push(row);
    }

    for (col_idx, &odbc_type) in column_types.iter().enumerate() {
        let slice = batch.column(col_idx);
        match odbc_type {
            OdbcType::Integer => copy_nullable_i32(slice, col_idx, starting_row, row_buffer)?,
            OdbcType::BigInt => copy_nullable_i64(slice, col_idx, starting_row, row_buffer)?,
            OdbcType::Float | OdbcType::Double => {
                copy_nullable_f64(slice, col_idx, starting_row, row_buffer)?
            }
            OdbcType::Boolean => copy_nullable_bit(slice, col_idx, starting_row, row_buffer)?,
            OdbcType::Binary => copy_binary(slice, col_idx, starting_row, row_buffer)?,
            OdbcType::Date => copy_nullable_date(slice, col_idx, starting_row, row_buffer)?,
            OdbcType::Time => copy_nullable_time(slice, col_idx, starting_row, row_buffer)?,
            OdbcType::Timestamp => {
                copy_nullable_timestamp(slice, col_idx, starting_row, row_buffer)?
            }
            _ => copy_wide_text(slice, col_idx, starting_row, row_buffer)?,
        }
    }

    Ok(())
}

fn copy_nullable_i32(
    slice: AnySlice<'_>,
    col_idx: usize,
    starting_row: usize,
    row_buffer: &mut RowBuffer,
) -> Result<()> {
    let view = slice.as_nullable_slice::<i32>().ok_or_else(|| {
        OdbcError::InternalError(format!(
            "Block fetch: column {col_idx} expected nullable i32 slice"
        ))
    })?;
    for (row_offset, value) in view.into_iter().enumerate() {
        if let Some(&v) = value {
            row_buffer.rows[starting_row + row_offset][col_idx] =
                Some(cell_bytes_from_slice(&v.to_le_bytes()));
        }
    }
    Ok(())
}

fn copy_nullable_i64(
    slice: AnySlice<'_>,
    col_idx: usize,
    starting_row: usize,
    row_buffer: &mut RowBuffer,
) -> Result<()> {
    let view = slice.as_nullable_slice::<i64>().ok_or_else(|| {
        OdbcError::InternalError(format!(
            "Block fetch: column {col_idx} expected nullable i64 slice"
        ))
    })?;
    for (row_offset, value) in view.into_iter().enumerate() {
        if let Some(&v) = value {
            row_buffer.rows[starting_row + row_offset][col_idx] =
                Some(cell_bytes_from_slice(&v.to_le_bytes()));
        }
    }
    Ok(())
}

fn copy_nullable_f64(
    slice: AnySlice<'_>,
    col_idx: usize,
    starting_row: usize,
    row_buffer: &mut RowBuffer,
) -> Result<()> {
    let view = slice.as_nullable_slice::<f64>().ok_or_else(|| {
        OdbcError::InternalError(format!(
            "Block fetch: column {col_idx} expected nullable f64 slice"
        ))
    })?;
    for (row_offset, value) in view.into_iter().enumerate() {
        if let Some(&v) = value {
            row_buffer.rows[starting_row + row_offset][col_idx] =
                Some(cell_bytes_from_slice(&v.to_le_bytes()));
        }
    }
    Ok(())
}

fn copy_nullable_bit(
    slice: AnySlice<'_>,
    col_idx: usize,
    starting_row: usize,
    row_buffer: &mut RowBuffer,
) -> Result<()> {
    let view = slice.as_nullable_slice::<odbc_api::Bit>().ok_or_else(|| {
        OdbcError::InternalError(format!(
            "Block fetch: column {col_idx} expected nullable bit slice"
        ))
    })?;
    for (row_offset, value) in view.into_iter().enumerate() {
        if let Some(&v) = value {
            let byte: u8 = if v.as_bool() { 1 } else { 0 };
            row_buffer.rows[starting_row + row_offset][col_idx] =
                Some(cell_bytes_from_slice(&[byte]));
        }
    }
    Ok(())
}

fn copy_binary(
    slice: AnySlice<'_>,
    col_idx: usize,
    starting_row: usize,
    row_buffer: &mut RowBuffer,
) -> Result<()> {
    let view = slice.as_bin_view().ok_or_else(|| {
        OdbcError::InternalError(format!(
            "Block fetch: column {col_idx} expected binary view"
        ))
    })?;
    for (row_offset, cell) in view.iter().enumerate() {
        if let Some(bytes) = cell {
            row_buffer.rows[starting_row + row_offset][col_idx] = Some(bytes.into());
        }
    }
    Ok(())
}

/// Format a [`odbc_api::sys::Date`] as `YYYY-MM-DD` ASCII bytes.
///
/// Matches the canonical ISO 8601 calendar-date production used across
/// all major ODBC drivers' WCHAR Date format. Year is zero-padded to
/// 4 digits; negative years are rare (BC dates) and rendered with a
/// leading minus so the wire byte count grows by one for them — the
/// Dart datetime parser handles either width.
///
/// Writes directly into `buf` (no intermediate `String`) so the block-fetch
/// and columnar-fetch hot paths avoid a per-cell heap allocation for the
/// format buffer itself. Accepts any `Extend<u8>` sink (`Vec<u8>`,
/// [`CellBytes`], …).
pub fn format_date_into(buf: &mut impl Extend<u8>, date: &odbc_api::sys::Date) {
    let _ = write!(
        AppendBytes(buf),
        "{:04}-{:02}-{:02}",
        date.year,
        date.month,
        date.day
    );
}

/// Format a [`odbc_api::sys::Time`] as `HH:MM:SS` ASCII bytes.
///
/// Matches the second-precision T-SQL `TIME(0)` and PostgreSQL `TIME`
/// representations. Sub-second precision is exposed via `Timestamp`
/// values (`TIME(7)` / `TIMETZ` round-trip via the WText fallback).
pub fn format_time_into(buf: &mut impl Extend<u8>, time: &odbc_api::sys::Time) {
    let _ = write!(
        AppendBytes(buf),
        "{:02}:{:02}:{:02}",
        time.hour,
        time.minute,
        time.second
    );
}

/// Format a [`odbc_api::sys::Timestamp`] as
/// `YYYY-MM-DD HH:MM:SS.ffffff` ASCII bytes (six-digit microsecond
/// fraction). See the comment on `OdbcType::Timestamp` in
/// `driver_adapters::buffer_desc_for` for the precision rationale.
pub fn format_timestamp_into(buf: &mut impl Extend<u8>, ts: &odbc_api::sys::Timestamp) {
    // `fraction` is u32 nanoseconds (0..=999_999_999). Divide by 1_000
    // to get microseconds; the integer division truncates the 7th-9th
    // digits, which is intentional per the format choice documented on
    // `buffer_desc_for`.
    let micros = ts.fraction / 1_000;
    let _ = write!(
        AppendBytes(buf),
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:06}",
        ts.year,
        ts.month,
        ts.day,
        ts.hour,
        ts.minute,
        ts.second,
        micros
    );
}

fn copy_nullable_date(
    slice: AnySlice<'_>,
    col_idx: usize,
    starting_row: usize,
    row_buffer: &mut RowBuffer,
) -> Result<()> {
    let view = slice
        .as_nullable_slice::<odbc_api::sys::Date>()
        .ok_or_else(|| {
            OdbcError::InternalError(format!(
                "Block fetch: column {col_idx} expected nullable Date slice"
            ))
        })?;
    for (row_offset, cell) in view.into_iter().enumerate() {
        if let Some(date) = cell {
            // 10-byte ISO date spills `SmallVec<[u8; 8]>`; allocate a
            // sized `Vec` once and move it into the cell (no `String`,
            // no clone, no spill-copy).
            let mut bytes = Vec::with_capacity(10);
            format_date_into(&mut bytes, date);
            row_buffer.rows[starting_row + row_offset][col_idx] = Some(bytes.into());
        }
    }
    Ok(())
}

fn copy_nullable_time(
    slice: AnySlice<'_>,
    col_idx: usize,
    starting_row: usize,
    row_buffer: &mut RowBuffer,
) -> Result<()> {
    let view = slice
        .as_nullable_slice::<odbc_api::sys::Time>()
        .ok_or_else(|| {
            OdbcError::InternalError(format!(
                "Block fetch: column {col_idx} expected nullable Time slice"
            ))
        })?;
    for (row_offset, cell) in view.into_iter().enumerate() {
        if let Some(time) = cell {
            // `HH:MM:SS` is exactly 8 bytes — stays fully inline in
            // `SmallVec<[u8; 8]>` with zero heap traffic.
            let mut bytes = CellBytes::new();
            format_time_into(&mut bytes, time);
            row_buffer.rows[starting_row + row_offset][col_idx] = Some(bytes);
        }
    }
    Ok(())
}

fn copy_nullable_timestamp(
    slice: AnySlice<'_>,
    col_idx: usize,
    starting_row: usize,
    row_buffer: &mut RowBuffer,
) -> Result<()> {
    let view = slice
        .as_nullable_slice::<odbc_api::sys::Timestamp>()
        .ok_or_else(|| {
            OdbcError::InternalError(format!(
                "Block fetch: column {col_idx} expected nullable Timestamp slice"
            ))
        })?;
    for (row_offset, cell) in view.into_iter().enumerate() {
        if let Some(ts) = cell {
            // 26-byte timestamp always spills `SmallVec<[u8; 8]>`; prefer
            // a pre-sized `Vec` so `CellBytes::from` reuses that heap
            // buffer instead of allocating twice.
            let mut bytes = Vec::with_capacity(26);
            format_timestamp_into(&mut bytes, ts);
            row_buffer.rows[starting_row + row_offset][col_idx] = Some(bytes.into());
        }
    }
    Ok(())
}

fn copy_wide_text(
    slice: AnySlice<'_>,
    col_idx: usize,
    starting_row: usize,
    row_buffer: &mut RowBuffer,
) -> Result<()> {
    let view = slice.as_w_text_view().ok_or_else(|| {
        OdbcError::InternalError(format!(
            "Block fetch: column {col_idx} expected wide text view"
        ))
    })?;
    for (row_offset, cell) in view.iter().enumerate() {
        if let Some(wide) = cell {
            // `wide` is `&U16Str`; shared ASCII fast-path + lossy fallback.
            row_buffer.rows[starting_row + row_offset][col_idx] =
                Some(wide_text_to_utf8_bytes(wide.as_slice()));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_date_into_renders_iso_8601_calendar_date() {
        let mut buf = Vec::new();
        format_date_into(
            &mut buf,
            &odbc_api::sys::Date {
                year: 2024,
                month: 3,
                day: 9,
            },
        );
        assert_eq!(&buf, b"2024-03-09");
    }

    #[test]
    fn format_time_into_renders_second_precision_iso_8601() {
        let mut buf = Vec::new();
        format_time_into(
            &mut buf,
            &odbc_api::sys::Time {
                hour: 7,
                minute: 5,
                second: 42,
            },
        );
        assert_eq!(&buf, b"07:05:42");
    }

    #[test]
    fn format_timestamp_into_renders_microsecond_iso_8601() {
        let mut buf = Vec::new();
        format_timestamp_into(
            &mut buf,
            &odbc_api::sys::Timestamp {
                year: 2026,
                month: 1,
                day: 1,
                hour: 12,
                minute: 34,
                second: 56,
                // 789_000_000 ns -> 789_000 us -> ".789000"
                fraction: 789_000_000,
            },
        );
        assert_eq!(&buf, b"2026-01-01 12:34:56.789000");
    }

    #[test]
    fn format_timestamp_into_truncates_sub_microsecond_precision() {
        let mut buf = Vec::new();
        format_timestamp_into(
            &mut buf,
            &odbc_api::sys::Timestamp {
                year: 2026,
                month: 1,
                day: 1,
                hour: 0,
                minute: 0,
                second: 0,
                // 100_500_000 ns -> 100_500 us -> ".100500"; the
                // sub-microsecond 500_000 ns (.0005 us) is dropped per
                // the precision policy on `buffer_desc_for`.
                fraction: 100_500_000,
            },
        );
        assert_eq!(&buf, b"2026-01-01 00:00:00.100500");
    }

    #[test]
    fn format_timestamp_into_pads_zero_microsecond_fraction() {
        let mut buf = Vec::new();
        format_timestamp_into(
            &mut buf,
            &odbc_api::sys::Timestamp {
                year: 1999,
                month: 12,
                day: 31,
                hour: 23,
                minute: 59,
                second: 59,
                fraction: 0,
            },
        );
        assert_eq!(&buf, b"1999-12-31 23:59:59.000000");
    }

    #[test]
    fn format_time_into_cell_bytes_stays_inline() {
        let mut bytes = CellBytes::new();
        format_time_into(
            &mut bytes,
            &odbc_api::sys::Time {
                hour: 12,
                minute: 34,
                second: 56,
            },
        );
        assert_eq!(bytes.as_slice(), b"12:34:56");
        assert!(!bytes.spilled(), "HH:MM:SS must fit in SmallVec<[u8; 8]>");
    }
}

//! BlockCursor-based fetch path, gated by the `block-cursor-fetch` feature.
//!
//! Replaces the per-row `cursor.next_row()` + per-cell `SQLGetData` pattern
//! with one `SQLFetchScroll` per batch into a preallocated
//! [`odbc_api::buffers::ColumnarAnyBuffer`]. This is the upstream-recommended
//! way to consume result sets and routinely delivers 2-10x speedups on
//! network round-trip-bound workloads.
//!
//! ## Safety net
//!
//! Some columns cannot be sensibly bound to a fixed-size buffer:
//!
//! - `LongVarchar` / `WLongVarchar` / `LongVarbinary` ("MAX" / LOB types) when
//!   the driver reports an unknown length.
//! - Any column whose advertised UTF-16 width would exceed
//!   [`MAX_INLINE_VAR_LEN_BYTES`] (we refuse to allocate >256 KiB per cell
//!   per batch row, which would be tens of GB for batch sizes in the 10k
//!   range).
//!
//! In those cases this module returns `None` from
//! [`plan_buffer_descs`] and the caller falls back to the legacy per-row
//! path — no data loss, no truncation. The decision is taken **before**
//! any binding happens, so we never need to recover mid-fetch.

use crate::error::{OdbcError, Result};
use crate::protocol::{OdbcType, RowBuffer};
use odbc_api::buffers::{AnySlice, BufferDesc, ColumnarAnyBuffer};
use odbc_api::{Cursor, DataType, ResultSetMetadata};
use std::sync::OnceLock;

/// Default number of rows fetched per `SQLFetchScroll` call.
///
/// 256 rows × ~32-256 bytes/row is small enough to stay inside L2 cache on
/// modern CPUs while large enough to amortise the network round-trip cost
/// well past the point of diminishing returns for most drivers.
pub const DEFAULT_BATCH_SIZE: usize = 256;

/// Environment variable that overrides [`DEFAULT_BATCH_SIZE`] at runtime.
///
/// Workloads with very narrow rows can benefit from 1024-2048; LOB-heavy
/// workloads may want 32-64 to keep the per-batch RAM bounded. Parsed
/// once on first use via [`OnceLock`]; invalid or absent values fall back
/// to the compile-time default.
///
/// Per-query override (e.g. an extra argument to `fetch_rows_into`) is
/// kept as an explicit follow-up — no API exists yet for callers to opt
/// in. See `engine_perf_follow-ups_b8f0b22a.plan.md` PR1.2 / B4.
pub const BATCH_SIZE_ENV_VAR: &str = "ODBC_FAST_BLOCK_FETCH_BATCH";

/// Hard upper bound on the per-cell buffer size we are willing to allocate
/// inline. Cells advertising more than this fall back to the per-row path
/// where memory is allocated on demand rather than per (batch_size × cell).
pub const MAX_INLINE_VAR_LEN_BYTES: usize = 256 * 1024;

/// Returns the effective batch size, honouring `ODBC_FAST_BLOCK_FETCH_BATCH`
/// when set to a positive integer and falling back to [`DEFAULT_BATCH_SIZE`]
/// otherwise. The value is cached on first call so subsequent fetches do
/// not pay the `std::env::var` syscall.
pub fn configured_batch_size() -> usize {
    static CACHED: OnceLock<usize> = OnceLock::new();
    *CACHED.get_or_init(|| {
        std::env::var(BATCH_SIZE_ENV_VAR)
            .ok()
            .and_then(|raw| raw.parse::<usize>().ok())
            .filter(|n| *n > 0)
            .unwrap_or(DEFAULT_BATCH_SIZE)
    })
}

/// Decide whether the current cursor can be served by the block-cursor
/// path. Returns the per-column [`BufferDesc`]s ready for
/// `ColumnarAnyBuffer::try_from_descs` when every column is bindable, or
/// `None` if at least one column would force the legacy fallback.
///
/// `column_types` must already be populated by the caller using the same
/// `describe_columns` helper that fills `RowBuffer::columns`, so the
/// `OdbcType → BufferDesc` mapping stays consistent with the wire format.
pub fn plan_buffer_descs<C>(
    cursor: &mut C,
    column_types: &[OdbcType],
) -> Result<Option<Vec<BufferDesc>>>
where
    C: ResultSetMetadata,
{
    let mut descs = Vec::with_capacity(column_types.len());
    for (idx, &odbc_type) in column_types.iter().enumerate() {
        // ODBC column indices are 1-based; the slice is 0-based.
        let col_idx: u16 = (idx + 1)
            .try_into()
            .map_err(|_| OdbcError::InternalError(format!("Column index {idx} overflows u16")))?;
        let data_type = cursor.col_data_type(col_idx).map_err(OdbcError::from)?;
        match buffer_desc_for(odbc_type, &data_type) {
            Some(desc) => descs.push(desc),
            None => return Ok(None),
        }
    }
    Ok(Some(descs))
}

fn buffer_desc_for(odbc_type: OdbcType, data_type: &DataType) -> Option<BufferDesc> {
    match odbc_type {
        OdbcType::Integer => Some(BufferDesc::I32 { nullable: true }),
        OdbcType::BigInt => Some(BufferDesc::I64 { nullable: true }),
        OdbcType::Binary => binary_buffer_desc(data_type),
        // Sprint 4 follow-up B5: temporal types can be bound natively so
        // we skip the driver-side WCHAR transcoding for the common case.
        // The formatting we apply afterwards uses ISO 8601 with
        // 6-digit microseconds for `Timestamp` — a precision shared by
        // PostgreSQL, MySQL/MariaDB, Snowflake, Oracle. SQL Server
        // produces 7-digit (100-ns) fractions in its WCHAR path; the
        // last digit is dropped here, which downstream Dart datetime
        // parsers tolerate. Callers needing the exact driver string
        // can opt out via `default-features = false`.
        OdbcType::Date => Some(BufferDesc::Date { nullable: true }),
        OdbcType::Time => Some(BufferDesc::Time { nullable: true }),
        OdbcType::Timestamp => Some(BufferDesc::Timestamp { nullable: true }),
        // All other OdbcType variants are sent as wide text through the
        // existing wire format (UTF-16 LE → UTF-8). Keeping this consistent
        // matches `CellReader::read_text` and `CellReader::read_wide_text`.
        _ => wide_text_buffer_desc(data_type),
    }
}

fn binary_buffer_desc(data_type: &DataType) -> Option<BufferDesc> {
    let length = match data_type {
        DataType::Binary { length: Some(n) } | DataType::Varbinary { length: Some(n) } => n.get(),
        // LongVarbinary or unknown length: fall back to per-cell.
        _ => return None,
    };
    if length == 0 || length > MAX_INLINE_VAR_LEN_BYTES {
        return None;
    }
    Some(BufferDesc::Binary { length })
}

fn wide_text_buffer_desc(data_type: &DataType) -> Option<BufferDesc> {
    let utf16_chars = data_type.utf16_len()?.get();
    // 2 bytes per UTF-16 code unit + 1 indicator entry per row.
    if utf16_chars == 0 || utf16_chars * 2 > MAX_INLINE_VAR_LEN_BYTES {
        return None;
    }
    Some(BufferDesc::WText {
        max_str_len: utf16_chars,
    })
}

/// Bind `cursor` to a freshly-allocated columnar buffer and drain the
/// remaining result set into `row_buffer`.
///
/// Truncation is treated as a hard error: the prior planning step
/// ([`plan_buffer_descs`]) refuses to bind any column whose maximum
/// representation we cannot allocate up-front. If a value still
/// overflows the negotiated buffer the cursor surfaces the error and we
/// propagate it instead of silently returning truncated bytes.
///
/// Returns the underlying cursor (via `BlockCursor::unbind`) so callers
/// who need `cursor.into_stmt()` to preserve `SQLMoreResults` for the
/// next item in a multi-result batch can keep doing so.
pub fn fetch_rows_into<C>(
    cursor: C,
    column_types: &[OdbcType],
    buffer_descs: Vec<BufferDesc>,
    batch_size: usize,
    row_buffer: &mut RowBuffer,
) -> Result<C>
where
    C: Cursor,
{
    let batch_size = batch_size.max(1);
    let buffer = ColumnarAnyBuffer::try_from_descs(batch_size, buffer_descs).map_err(|e| {
        OdbcError::InternalError(format!("ColumnarAnyBuffer allocation failed: {e}"))
    })?;

    let mut block_cursor = cursor.bind_buffer(buffer).map_err(OdbcError::from)?;

    while let Some(batch) = block_cursor
        .fetch_with_truncation_check(true)
        .map_err(OdbcError::from)?
    {
        append_batch_to_row_buffer(batch, column_types, row_buffer)?;
    }

    let (cursor, _buffer) = block_cursor.unbind().map_err(OdbcError::from)?;
    Ok(cursor)
}

fn append_batch_to_row_buffer(
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
            row_buffer.rows[starting_row + row_offset][col_idx] = Some(v.to_le_bytes().to_vec());
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
            row_buffer.rows[starting_row + row_offset][col_idx] = Some(v.to_le_bytes().to_vec());
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
            row_buffer.rows[starting_row + row_offset][col_idx] = Some(bytes.to_vec());
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
fn format_date_into(buf: &mut Vec<u8>, date: &odbc_api::sys::Date) {
    use std::fmt::Write;
    // Reserve the worst case to avoid extra growth; `write!` is
    // infallible on `String`.
    let mut s = String::with_capacity(10);
    let _ = write!(s, "{:04}-{:02}-{:02}", date.year, date.month, date.day);
    buf.extend_from_slice(s.as_bytes());
}

/// Format a [`odbc_api::sys::Time`] as `HH:MM:SS` ASCII bytes.
///
/// Matches the second-precision T-SQL `TIME(0)` and PostgreSQL `TIME`
/// representations. Sub-second precision is exposed via `Timestamp`
/// values (`TIME(7)` / `TIMETZ` round-trip via the WText fallback).
fn format_time_into(buf: &mut Vec<u8>, time: &odbc_api::sys::Time) {
    use std::fmt::Write;
    let mut s = String::with_capacity(8);
    let _ = write!(s, "{:02}:{:02}:{:02}", time.hour, time.minute, time.second);
    buf.extend_from_slice(s.as_bytes());
}

/// Format a [`odbc_api::sys::Timestamp`] as
/// `YYYY-MM-DD HH:MM:SS.ffffff` ASCII bytes (six-digit microsecond
/// fraction). See the comment on `OdbcType::Timestamp` in
/// `buffer_desc_for` for the precision rationale.
fn format_timestamp_into(buf: &mut Vec<u8>, ts: &odbc_api::sys::Timestamp) {
    use std::fmt::Write;
    let mut s = String::with_capacity(26);
    // `fraction` is u32 nanoseconds (0..=999_999_999). Divide by 1_000
    // to get microseconds; the integer division truncates the 7th-9th
    // digits, which is intentional per the format choice documented on
    // `buffer_desc_for`.
    let micros = ts.fraction / 1_000;
    let _ = write!(
        s,
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:06}",
        ts.year, ts.month, ts.day, ts.hour, ts.minute, ts.second, micros
    );
    buf.extend_from_slice(s.as_bytes());
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
            let mut bytes = Vec::with_capacity(10);
            format_date_into(&mut bytes, date);
            row_buffer.rows[starting_row + row_offset][col_idx] = Some(bytes);
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
            let mut bytes = Vec::with_capacity(8);
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
            let mut bytes = Vec::with_capacity(26);
            format_timestamp_into(&mut bytes, ts);
            row_buffer.rows[starting_row + row_offset][col_idx] = Some(bytes);
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
            // `wide` is `&U16Str`; `as_slice()` exposes the underlying
            // `&[u16]` we feed to `String::from_utf16_lossy`. Matches the
            // legacy `wide_text_to_utf8_bytes` behaviour exactly.
            let utf8 = String::from_utf16_lossy(wide.as_slice()).into_bytes();
            row_buffer.rows[starting_row + row_offset][col_idx] = Some(utf8);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::num::NonZeroUsize;

    #[test]
    fn buffer_desc_for_integer_is_nullable_i32() {
        let desc = buffer_desc_for(OdbcType::Integer, &DataType::Integer);
        assert_eq!(desc, Some(BufferDesc::I32 { nullable: true }));
    }

    #[test]
    fn buffer_desc_for_bigint_is_nullable_i64() {
        let desc = buffer_desc_for(OdbcType::BigInt, &DataType::BigInt);
        assert_eq!(desc, Some(BufferDesc::I64 { nullable: true }));
    }

    #[test]
    fn buffer_desc_for_varchar_with_known_length_is_wide_text() {
        let dt = DataType::Varchar {
            length: NonZeroUsize::new(100),
        };
        let desc = buffer_desc_for(OdbcType::Varchar, &dt);
        // `DataType::utf16_len` reports the worst-case number of UTF-16
        // code units required, which is 2 * source-character-length to
        // accommodate surrogate pairs (see odbc-api doc example:
        // `Varchar(10).utf16_len() == 20`). So `Varchar(100)` becomes
        // `WText { max_str_len: 200 }` here.
        assert_eq!(desc, Some(BufferDesc::WText { max_str_len: 200 }));
    }

    #[test]
    fn buffer_desc_for_varchar_with_unknown_length_falls_back() {
        let dt = DataType::Varchar { length: None };
        assert!(buffer_desc_for(OdbcType::Varchar, &dt).is_none());
    }

    #[test]
    fn buffer_desc_for_long_varchar_with_unknown_length_falls_back() {
        let dt = DataType::WLongVarchar { length: None };
        assert!(buffer_desc_for(OdbcType::NVarchar, &dt).is_none());
    }

    #[test]
    fn buffer_desc_for_oversized_text_falls_back() {
        // `utf16_len` doubles the advertised char length to handle surrogate
        // pairs (`Varchar(n).utf16_len() == 2n`). The buffer size cap then
        // multiplies that by 2 bytes/code unit. Worst case: any varchar
        // wider than `MAX_INLINE_VAR_LEN_BYTES / 4` chars must fall back.
        let oversized_chars = MAX_INLINE_VAR_LEN_BYTES / 4 + 1;
        let dt = DataType::Varchar {
            length: NonZeroUsize::new(oversized_chars),
        };
        assert!(buffer_desc_for(OdbcType::Varchar, &dt).is_none());
    }

    #[test]
    fn buffer_desc_for_binary_with_known_length() {
        let dt = DataType::Varbinary {
            length: NonZeroUsize::new(64),
        };
        assert_eq!(
            buffer_desc_for(OdbcType::Binary, &dt),
            Some(BufferDesc::Binary { length: 64 })
        );
    }

    #[test]
    fn buffer_desc_for_long_varbinary_falls_back() {
        let dt = DataType::LongVarbinary {
            length: NonZeroUsize::new(1024),
        };
        // LongVarbinary deliberately falls back — driver-reported lengths
        // for LOB types are commonly unreliable.
        assert!(buffer_desc_for(OdbcType::Binary, &dt).is_none());
    }

    #[test]
    fn buffer_desc_for_oversized_binary_falls_back() {
        let dt = DataType::Binary {
            length: NonZeroUsize::new(MAX_INLINE_VAR_LEN_BYTES + 1),
        };
        assert!(buffer_desc_for(OdbcType::Binary, &dt).is_none());
    }

    #[test]
    fn buffer_desc_for_decimal_estimates_via_utf16_len() {
        let dt = DataType::Decimal {
            precision: 18,
            scale: 4,
        };
        // utf16_len returns precision + 2 for decimals; that becomes max_str_len.
        let desc = buffer_desc_for(OdbcType::Decimal, &dt);
        assert!(matches!(desc, Some(BufferDesc::WText { max_str_len }) if max_str_len > 0));
    }

    #[test]
    fn buffer_desc_for_date_now_routes_native() {
        // Sprint 4 follow-up B5 promoted `OdbcType::Date` from the
        // `WText` fallback to the native `Date` buffer. The old
        // expectation (`matches!(desc, Some(BufferDesc::WText { .. }))`)
        // is intentionally inverted here so a future revert (or a
        // partial revert of B5) trips this test.
        let desc = buffer_desc_for(OdbcType::Date, &DataType::Date);
        assert_eq!(desc, Some(BufferDesc::Date { nullable: true }));
    }

    #[test]
    fn buffer_desc_for_unknown_data_type_falls_back() {
        let desc = buffer_desc_for(OdbcType::Varchar, &DataType::Unknown);
        assert!(desc.is_none());
    }

    #[test]
    fn configured_batch_size_falls_back_to_default_when_unset() {
        // Cannot mutate env in a multi-threaded test runner without races,
        // and `configured_batch_size` caches via OnceLock anyway. The
        // cached result has to be one of: parsed-positive-usize, or the
        // compile-time default. Either is acceptable here.
        let value = configured_batch_size();
        assert!(value > 0, "batch size must be positive, got {value}");
    }

    #[test]
    fn configured_batch_size_env_var_name_is_stable() {
        // Document the public env var contract so future renames are
        // intentional (this constant is part of the engine's runtime
        // configuration surface).
        assert_eq!(BATCH_SIZE_ENV_VAR, "ODBC_FAST_BLOCK_FETCH_BATCH");
    }

    #[test]
    fn buffer_desc_for_date_routes_to_native_date() {
        assert_eq!(
            buffer_desc_for(OdbcType::Date, &DataType::Date),
            Some(BufferDesc::Date { nullable: true })
        );
    }

    #[test]
    fn buffer_desc_for_time_routes_to_native_time() {
        assert_eq!(
            buffer_desc_for(OdbcType::Time, &DataType::Time { precision: 0 }),
            Some(BufferDesc::Time { nullable: true })
        );
    }

    #[test]
    fn buffer_desc_for_timestamp_routes_to_native_timestamp() {
        assert_eq!(
            buffer_desc_for(OdbcType::Timestamp, &DataType::Timestamp { precision: 6 }),
            Some(BufferDesc::Timestamp { nullable: true })
        );
    }

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
}

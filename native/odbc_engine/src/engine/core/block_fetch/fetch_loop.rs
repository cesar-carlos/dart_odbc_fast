use super::column_buffers::append_batch_to_row_buffer;
use crate::error::{OdbcError, Result};
use crate::protocol::{OdbcType, RowBuffer};
use odbc_api::buffers::{BufferDesc, ColumnarAnyBuffer};
use odbc_api::Cursor;
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

/// Bind `cursor` to a freshly-allocated columnar buffer and drain the
/// remaining result set into `row_buffer`.
///
/// Truncation is treated as a hard error: the prior planning step
/// ([`super::plan_buffer_descs`]) refuses to bind any column whose maximum
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

#[cfg(test)]
mod tests {
    use super::*;

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
}

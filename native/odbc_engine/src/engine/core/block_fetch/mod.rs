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

mod column_buffers;
mod driver_adapters;
mod fetch_loop;

pub use driver_adapters::plan_buffer_descs;
pub use fetch_loop::{
    configured_batch_size, fetch_rows_into, BATCH_SIZE_ENV_VAR, DEFAULT_BATCH_SIZE,
};

/// Hard upper bound on the per-cell buffer size we are willing to allocate
/// inline. Cells advertising more than this fall back to the per-row path
/// where memory is allocated on demand rather than per (batch_size × cell).
pub const MAX_INLINE_VAR_LEN_BYTES: usize = 256 * 1024;

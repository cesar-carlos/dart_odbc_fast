//! SQL Server native BCP (Bulk Copy Program) implementation.
//!
//! # DLL Compatibility
//!
//! - **sqlncli11.dll** (SQL Server Native Client 11.0): Fully compatible with `bcp_initW` and all BCP functions.
//! - **msodbcsql17.dll** / **msodbcsql18.dll** (Microsoft ODBC Driver 17/18): `bcp_initW` fails with rc=0 (known issue).
//!
//! We prioritize `sqlncli11.dll` for BCP operations. If unavailable, we attempt modern drivers but may fall back to ArrayBinding.
//!
//! # bcp_collen Usage
//!
//! `bcp_collen` sets the column length for **all subsequent rows** until called again. For nullable columns:
//! - Must call `bcp_collen(SQL_NULL_DATA)` for null rows
//! - Must call `bcp_collen(actual_size)` for non-null rows after a null row
//! - Safest approach: call `bcp_collen` for **every row** to avoid state persistence bugs

mod bound_column;
mod execute;
mod helpers;
mod library;
mod payload;

#[cfg(test)]
mod tests;

use crate::error::{OdbcError, Result};
use crate::protocol::BulkInsertPayload;

use library::{probe_library, CANDIDATE_LIBRARIES};
use payload::build_bound_columns;

pub fn probe_native_bcp_support() -> Result<()> {
    let mut load_errors: Vec<String> = Vec::new();

    for candidate in CANDIDATE_LIBRARIES {
        match probe_library(candidate) {
            Ok(()) => return Ok(()),
            Err(err) => load_errors.push(format!("{candidate}: {err}")),
        }
    }

    Err(OdbcError::UnsupportedFeature(format!(
        "Unable to load SQL Server BCP libraries from PATH. Tried: {}",
        load_errors.join(" | ")
    )))
}

pub fn execute_native_bcp(
    conn_str: &str,
    payload: &BulkInsertPayload,
    batch_size: usize,
) -> Result<usize> {
    if payload.columns.is_empty() {
        return Ok(0);
    }
    let mut bound_columns = build_bound_columns(payload)?;
    let row_count = payload.row_count as usize;
    for (idx, col) in bound_columns.iter().enumerate() {
        if col.len() != row_count {
            return Err(OdbcError::ValidationError(format!(
                "Native BCP payload column {} has {} rows, expected {}",
                idx,
                col.len(),
                row_count
            )));
        }
    }

    execute::run_native_bcp(conn_str, payload, batch_size, &mut bound_columns, row_count)
}

//! Native bulk-load capability.
//!
//! Implementations bypass the standard prepared INSERT path and use the
//! engine-native fastest route:
//!
//! - **SQL Server**: `bcp_initW` + `bcp_sendrow` (already implemented in
//!   `engine::core::sqlserver_bcp`).
//! - **PostgreSQL**: `COPY ... FROM STDIN BINARY` via `SQLPutData` chunks.
//! - **MySQL/MariaDB**: `LOAD DATA LOCAL INFILE` against a temp CSV.
//! - **Oracle**: `INSERT /*+ APPEND */ ...` direct-path (via array binding).
//! - **Snowflake**: `PUT file://... ; COPY INTO ...` (file-staged).

use crate::error::Result;
use crate::protocol::BulkInsertPayload;
use odbc_api::Connection;

/// Tunable behaviour for native bulk loaders.
#[derive(Debug, Clone)]
pub struct BulkLoadOptions {
    /// Maximum rows committed per native call (when applicable).
    pub batch_size: usize,
    /// Marker written for NULL values when the path uses a text format
    /// (CSV-style). Ignored by binary paths (BCP, PG COPY BINARY).
    pub null_marker: String,
    /// Field delimiter for text formats. Default: `\t` (tab).
    pub delimiter: char,
    /// Per-row timeout in seconds; `None` means "use connection default".
    pub timeout_secs: Option<u32>,
    /// When true, the loader is allowed to keep its temporary spill files on
    /// failure for debugging (default: false → cleanup unconditionally).
    pub keep_temp_on_failure: bool,
}

impl BulkLoadOptions {
    pub fn new(batch_size: usize) -> Self {
        Self {
            batch_size: batch_size.max(1),
            null_marker: "\\N".to_string(),
            delimiter: '\t',
            timeout_secs: None,
            keep_temp_on_failure: false,
        }
    }
}

impl Default for BulkLoadOptions {
    fn default() -> Self {
        Self::new(10_000)
    }
}

/// Capability trait for engines with a native bulk-load fast path.
///
/// Plugins that do not have one simply do not implement this trait.
pub trait BulkLoader: Send + Sync {
    /// Stable identifier for the underlying technique
    /// (`"bcp"`, `"copy_binary"`, `"load_data"`, `"direct_path"`, `"put_copy"`).
    fn technique(&self) -> &'static str;

    /// Quick check (no I/O) — when `false`, the runtime must use the fallback
    /// path without calling `execute_bulk_native`. Useful when the technique
    /// requires runtime preconditions (Windows-only DLLs, server flags).
    fn supports_native_bulk(&self) -> bool {
        true
    }

    /// Run the native loader against the live connection.
    ///
    /// Implementations may return `OdbcError::UnsupportedFeature` to signal the
    /// caller should retry through `ArrayBinding` (the wire fallback).
    fn execute_bulk_native(
        &self,
        conn: &Connection<'static>,
        payload: &BulkInsertPayload,
        options: &BulkLoadOptions,
    ) -> Result<usize>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_defaults_are_sane() {
        let o = BulkLoadOptions::default();
        assert_eq!(o.batch_size, 10_000);
        assert_eq!(o.delimiter, '\t');
        assert_eq!(o.null_marker, "\\N");
        assert_eq!(o.timeout_secs, None);
        assert!(!o.keep_temp_on_failure);
    }

    #[test]
    fn options_new_clamps_batch_to_at_least_one() {
        let o = BulkLoadOptions::new(0);
        assert_eq!(o.batch_size, 1);
    }
}

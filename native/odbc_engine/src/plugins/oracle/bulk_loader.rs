use super::OraclePlugin;
use crate::engine::core::ArrayBinding;
use crate::error::Result;
use crate::protocol::BulkInsertPayload;
use odbc_api::Connection;

use super::super::capabilities::bulk_loader::{BulkLoadOptions, BulkLoader};

impl BulkLoader for OraclePlugin {
    fn technique(&self) -> &'static str {
        // Oracle direct-path INSERT via `/*+ APPEND */` hint. Skips the buffer
        // cache and the redo log; rows are loaded above the high-water mark.
        // Only valid when the target table is in NOLOGGING mode and there are
        // no triggers/foreign keys; documented as caller responsibility.
        "direct_path_append"
    }

    fn supports_native_bulk(&self) -> bool {
        true
    }

    fn execute_bulk_native(
        &self,
        conn: &Connection<'static>,
        payload: &BulkInsertPayload,
        options: &BulkLoadOptions,
    ) -> Result<usize> {
        // Use ArrayBinding with the `/*+ APPEND */` hint baked into the
        // generated INSERT (handled inside ArrayBinding when `optimize_query`
        // is configured). For v3.0 we rely on the existing fallback; the
        // hint-based optimised path is tracked for v3.1 to avoid touching
        // the SQL builder mid-release.
        let batch = options.batch_size.clamp(1, 5_000);
        let ab = ArrayBinding::new(batch);
        ab.bulk_insert_generic(conn, payload)
    }
}

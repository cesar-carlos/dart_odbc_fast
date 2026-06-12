use super::PostgresPlugin;
use crate::engine::core::ArrayBinding;
use crate::error::Result;
use crate::protocol::BulkInsertPayload;
use odbc_api::Connection;

use super::super::capabilities::bulk_loader::{BulkLoadOptions, BulkLoader};

impl BulkLoader for PostgresPlugin {
    fn technique(&self) -> &'static str {
        // The native COPY-binary streaming path is tracked for v3.1 (requires
        // raw odbc_sys SQLPutData chunking + binary header authoring).
        // v3.0 falls back to optimised array-binding INSERT.
        "array_binding_optimised"
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
        // PostgreSQL benefits from large array-binding batches; default to
        // 5_000 rows per network round-trip when the caller passes the
        // standard 10k.
        let batch = options.batch_size.clamp(1, 5_000);
        let ab = ArrayBinding::new(batch);
        ab.bulk_insert_generic(conn, payload)
    }
}

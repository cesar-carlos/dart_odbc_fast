use super::MySqlPlugin;
use crate::engine::core::ArrayBinding;
use crate::error::Result;
use crate::protocol::BulkInsertPayload;
use odbc_api::Connection;

use super::super::capabilities::bulk_loader::{BulkLoadOptions, BulkLoader};

impl BulkLoader for MySqlPlugin {
    fn technique(&self) -> &'static str {
        // LOAD DATA LOCAL INFILE streaming is tracked for v3.1 (requires
        // server flag `local_infile=1` plus client-side temp file management).
        // v3.0 uses optimised array-binding multi-row INSERT.
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
        let batch = options.batch_size.clamp(1, 2_000);
        let ab = ArrayBinding::new(batch);
        ab.bulk_insert_generic(conn, payload)
    }
}

//! IBM Db2 plugin (NEW in v3.0).
//!
//! - `FETCH FIRST n ROWS ONLY` (Db2 syntax).
//! - `MERGE INTO` for UPSERT.
//! - `SELECT ... FROM FINAL TABLE (INSERT ...)` for RETURNING-equivalent.

mod catalog;
mod returning;
mod session;
mod type_catalog;
mod upsert;

#[cfg(test)]
mod tests;

use super::capabilities::IdentifierQuoter;
use super::driver_plugin::{DriverCapabilities, DriverPlugin, OptimizationRule};
use crate::protocol::types::OdbcType;

pub struct Db2Plugin;

impl Default for Db2Plugin {
    fn default() -> Self {
        Self::new()
    }
}

impl Db2Plugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for Db2Plugin {
    fn name(&self) -> &str {
        "db2"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 2000,
            driver_name: "IBM Db2".to_string(),
            driver_version: "Unknown".to_string(),
        }
    }

    fn map_type(&self, odbc_type: i16) -> OdbcType {
        OdbcType::from_odbc_sql_type(odbc_type)
    }

    fn optimize_query(&self, sql: &str) -> String {
        let mut optimized = sql.to_string();
        if optimized.contains("SELECT") && !optimized.to_uppercase().contains("FETCH FIRST") {
            if let Some(pos) = optimized.rfind(';') {
                optimized.insert_str(pos, " FETCH FIRST 1000 ROWS ONLY");
            } else if !optimized.to_uppercase().contains(" WHERE")
                && !optimized.to_uppercase().contains(" ORDER BY")
            {
                optimized.push_str(" FETCH FIRST 1000 ROWS ONLY");
            }
        }
        optimized
    }

    fn get_optimization_rules(&self) -> Vec<OptimizationRule> {
        vec![
            OptimizationRule::UsePreparedStatements,
            OptimizationRule::UseBatchOperations,
            OptimizationRule::UseArrayFetch { size: 2000 },
            OptimizationRule::EnableStreaming,
        ]
    }
}

impl IdentifierQuoter for Db2Plugin {}

//! MariaDB plugin (NEW in v3.0).
//!
//! MariaDB is wire-compatible with MySQL but adds:
//! - `RETURNING` clause (MariaDB 10.5+)
//! - `INSERT ... ON DUPLICATE KEY UPDATE` (same as MySQL)
//!
//! Until v3.0 the registry mapped MariaDB to the MySQL plugin; this dedicated
//! plugin enables RETURNING and provides MariaDB-specific type mapping.

mod catalog;
mod returning;
mod session;
mod type_catalog;
mod upsert;

#[cfg(test)]
mod tests;

use super::capabilities::IdentifierQuoter;
use super::driver_plugin::{DriverCapabilities, DriverPlugin, OptimizationRule};
use crate::engine::identifier::IdentifierQuoting;
use crate::protocol::types::OdbcType;

pub struct MariaDbPlugin;

impl Default for MariaDbPlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl MariaDbPlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for MariaDbPlugin {
    fn name(&self) -> &str {
        "mariadb"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 1500,
            driver_name: "MariaDB".to_string(),
            driver_version: "Unknown".to_string(),
        }
    }

    fn map_type(&self, odbc_type: i16) -> OdbcType {
        OdbcType::from_odbc_sql_type(odbc_type)
    }

    fn optimize_query(&self, sql: &str) -> String {
        let mut optimized = sql.to_string();
        if optimized.contains("SELECT") && !optimized.to_uppercase().contains(" LIMIT") {
            if let Some(pos) = optimized.rfind(';') {
                optimized.insert_str(pos, " LIMIT 1000");
            } else if !optimized.to_uppercase().contains(" WHERE")
                && !optimized.to_uppercase().contains(" ORDER BY")
            {
                optimized.push_str(" LIMIT 1000");
            }
        }
        optimized
    }

    fn get_optimization_rules(&self) -> Vec<OptimizationRule> {
        vec![
            OptimizationRule::UsePreparedStatements,
            OptimizationRule::UseBatchOperations,
            OptimizationRule::UseArrayFetch { size: 1500 },
            OptimizationRule::EnableStreaming,
        ]
    }
}

impl IdentifierQuoter for MariaDbPlugin {
    fn quoting_style(&self) -> IdentifierQuoting {
        IdentifierQuoting::Backtick
    }
}

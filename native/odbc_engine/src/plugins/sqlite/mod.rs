//! SQLite plugin (NEW in v3.0).
//!
//! SQLite is unusual:
//! - dynamic typing (storage classes vs declared types)
//! - no `LIMIT` rewrite needed (file-based, sub-millisecond planning)
//! - `ON CONFLICT` clause supported since 3.24
//! - `RETURNING` supported since 3.35

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

pub struct SqlitePlugin;

impl Default for SqlitePlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl SqlitePlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for SqlitePlugin {
    fn name(&self) -> &str {
        "sqlite"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 1000,
            driver_name: "SQLite".to_string(),
            driver_version: "Unknown".to_string(),
        }
    }

    fn map_type(&self, odbc_type: i16) -> OdbcType {
        // SQLite ODBC drivers (e.g. SQLite ODBC by Christian Werner) usually
        // report storage classes via SQL types; honour the standard mapping.
        OdbcType::from_odbc_sql_type(odbc_type)
    }

    fn optimize_query(&self, sql: &str) -> String {
        // No automatic LIMIT injection: SQLite is file-based and the planner
        // is fast enough that the heuristic LIMIT 1000 used by other drivers
        // would surprise users.
        sql.to_string()
    }

    fn get_optimization_rules(&self) -> Vec<OptimizationRule> {
        vec![
            OptimizationRule::UsePreparedStatements,
            OptimizationRule::UseBatchOperations,
            OptimizationRule::UseArrayFetch { size: 1000 },
        ]
    }
}

impl IdentifierQuoter for SqlitePlugin {
    // SQLite accepts double-quotes (ANSI) and backticks (MySQL-compat) and
    // brackets (T-SQL-compat). Default to double-quotes.
}

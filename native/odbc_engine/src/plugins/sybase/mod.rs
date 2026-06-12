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

pub struct SybasePlugin;

impl Default for SybasePlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl SybasePlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for SybasePlugin {
    fn name(&self) -> &str {
        "sybase"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 500,
            driver_name: "Sybase".to_string(),
            driver_version: "Unknown".to_string(),
        }
    }

    fn map_type(&self, odbc_type: i16) -> OdbcType {
        match odbc_type {
            1 => OdbcType::Varchar,
            4 => OdbcType::Integer,
            -5 => OdbcType::BigInt,
            3 => OdbcType::Decimal,
            9 => OdbcType::Date,
            11 => OdbcType::Timestamp,
            -2 => OdbcType::Binary,
            _ => OdbcType::Varchar,
        }
    }

    fn optimize_query(&self, sql: &str) -> String {
        sql.to_string()
    }

    fn get_optimization_rules(&self) -> Vec<OptimizationRule> {
        vec![
            OptimizationRule::UsePreparedStatements,
            OptimizationRule::UseBatchOperations,
            OptimizationRule::UseArrayFetch { size: 500 },
            OptimizationRule::EnableStreaming,
        ]
    }
}

impl IdentifierQuoter for SybasePlugin {
    fn quoting_style(&self) -> IdentifierQuoting {
        // ASE uses brackets / "double quotes" (with QUOTED_IDENTIFIER ON);
        // ASA accepts both. Default to brackets since they're always safe in ASE.
        IdentifierQuoting::Brackets
    }
}

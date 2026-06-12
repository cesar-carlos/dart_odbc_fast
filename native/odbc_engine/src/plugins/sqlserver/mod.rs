mod catalog;
mod quoting;
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

pub struct SqlServerPlugin;

impl Default for SqlServerPlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl SqlServerPlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for SqlServerPlugin {
    fn name(&self) -> &str {
        "sqlserver"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 1000,
            driver_name: "SQL Server".to_string(),
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
        let mut optimized = sql.to_string();

        if optimized.contains("SELECT *") && !optimized.contains("TOP") {
            if let Some(pos) = optimized.find("SELECT *") {
                optimized.replace_range(pos..pos + 8, "SELECT TOP 1000 *");
            }
        }

        optimized
    }

    fn get_optimization_rules(&self) -> Vec<OptimizationRule> {
        vec![
            OptimizationRule::UsePreparedStatements,
            OptimizationRule::UseBatchOperations,
            OptimizationRule::UseArrayFetch { size: 1000 },
            OptimizationRule::EnableStreaming,
        ]
    }
}

impl IdentifierQuoter for SqlServerPlugin {
    fn quoting_style(&self) -> IdentifierQuoting {
        IdentifierQuoting::Brackets
    }
}

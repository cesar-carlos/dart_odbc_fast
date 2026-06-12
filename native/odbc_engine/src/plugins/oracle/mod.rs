mod bulk_loader;
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

pub struct OraclePlugin;

impl Default for OraclePlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl OraclePlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for OraclePlugin {
    fn name(&self) -> &str {
        "oracle"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 5000,
            driver_name: "Oracle".to_string(),
            driver_version: "Unknown".to_string(),
        }
    }

    fn map_type(&self, odbc_type: i16) -> OdbcType {
        match odbc_type {
            1 => OdbcType::Varchar,
            2 | 4 => OdbcType::Integer, // 2 = Oracle, 4 = ODBC SQL_INTEGER
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

        if optimized.contains("SELECT")
            && !optimized.contains("ROWNUM")
            && !optimized.contains("FETCH")
        {
            if let Some(pos) = optimized.rfind(';') {
                optimized.insert_str(pos, " FETCH FIRST 1000 ROWS ONLY");
            } else if !optimized.contains("WHERE") && !optimized.contains("ORDER BY") {
                optimized.push_str(" FETCH FIRST 1000 ROWS ONLY");
            }
        }

        optimized
    }

    fn get_optimization_rules(&self) -> Vec<OptimizationRule> {
        vec![
            OptimizationRule::UsePreparedStatements,
            OptimizationRule::UseBatchOperations,
            OptimizationRule::UseArrayFetch { size: 5000 },
            OptimizationRule::EnableStreaming,
        ]
    }
}

impl IdentifierQuoter for OraclePlugin {
    // Oracle uses ANSI double-quoted identifiers.
    // Note: Oracle FOLDS UNQUOTED IDENTIFIERS TO UPPERCASE; quoted are case-sensitive.
}

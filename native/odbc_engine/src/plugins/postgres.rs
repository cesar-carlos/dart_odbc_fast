use super::driver_plugin::{DriverCapabilities, DriverPlugin, OptimizationRule};
use crate::protocol::types::OdbcType;

pub struct PostgresPlugin;

impl Default for PostgresPlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl PostgresPlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for PostgresPlugin {
    fn name(&self) -> &str {
        "postgres"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 1000,
            driver_name: "PostgreSQL".to_string(),
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

        if optimized.contains("SELECT") && !optimized.contains("LIMIT") {
            if let Some(pos) = optimized.rfind(';') {
                optimized.insert_str(pos, " LIMIT 1000");
            } else if !optimized.contains("WHERE") && !optimized.contains("ORDER BY") {
                optimized.push_str(" LIMIT 1000");
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_postgres_plugin_new() {
        let plugin = PostgresPlugin::new();
        assert_eq!(plugin.name(), "postgres");
    }

    #[test]
    fn test_postgres_plugin_default() {
        let plugin = PostgresPlugin;
        assert_eq!(plugin.name(), "postgres");
    }

    #[test]
    fn test_postgres_plugin_name() {
        let plugin = PostgresPlugin::new();
        assert_eq!(plugin.name(), "postgres");
    }

    #[test]
    fn test_postgres_plugin_capabilities() {
        let plugin = PostgresPlugin::new();
        let caps = plugin.get_capabilities();

        assert!(caps.supports_prepared_statements);
        assert!(caps.supports_batch_operations);
        assert!(caps.supports_streaming);
        assert!(caps.supports_array_fetch);
        assert_eq!(caps.max_row_array_size, 1000);
        assert_eq!(caps.driver_name, "PostgreSQL");
        assert_eq!(caps.driver_version, "Unknown");
    }

    #[test]
    fn test_postgres_plugin_map_type() {
        let plugin = PostgresPlugin::new();

        assert_eq!(plugin.map_type(1), OdbcType::Varchar);
        assert_eq!(plugin.map_type(4), OdbcType::Integer);
        assert_eq!(plugin.map_type(-5), OdbcType::BigInt);
        assert_eq!(plugin.map_type(3), OdbcType::Decimal);
        assert_eq!(plugin.map_type(9), OdbcType::Date);
        assert_eq!(plugin.map_type(11), OdbcType::Timestamp);
        assert_eq!(plugin.map_type(-2), OdbcType::Binary);
        assert_eq!(plugin.map_type(99), OdbcType::Varchar); // Default case
    }

    #[test]
    fn test_postgres_plugin_optimize_query_select_without_limit() {
        let plugin = PostgresPlugin::new();

        let sql = "SELECT * FROM users";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 1000");
    }

    #[test]
    fn test_postgres_plugin_optimize_query_select_with_semicolon() {
        let plugin = PostgresPlugin::new();

        let sql = "SELECT * FROM users;";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 1000;");
    }

    #[test]
    fn test_postgres_plugin_optimize_query_already_has_limit() {
        let plugin = PostgresPlugin::new();

        let sql = "SELECT * FROM users LIMIT 500";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 500");
    }

    #[test]
    fn test_postgres_plugin_optimize_query_with_where() {
        let plugin = PostgresPlugin::new();

        let sql = "SELECT * FROM users WHERE id > 10";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users WHERE id > 10");
    }

    #[test]
    fn test_postgres_plugin_optimize_query_with_order_by() {
        let plugin = PostgresPlugin::new();

        let sql = "SELECT * FROM users ORDER BY name";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users ORDER BY name");
    }

    #[test]
    fn test_postgres_plugin_get_optimization_rules() {
        let plugin = PostgresPlugin::new();
        let rules = plugin.get_optimization_rules();

        assert_eq!(rules.len(), 4);
        assert!(matches!(rules[0], OptimizationRule::UsePreparedStatements));
        assert!(matches!(rules[1], OptimizationRule::UseBatchOperations));
        assert!(matches!(
            rules[2],
            OptimizationRule::UseArrayFetch { size: 1000 }
        ));
        assert!(matches!(rules[3], OptimizationRule::EnableStreaming));
    }
}

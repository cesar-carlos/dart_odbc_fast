use super::driver_plugin::{DriverCapabilities, DriverPlugin, OptimizationRule};
use crate::protocol::types::OdbcType;

pub struct MySqlPlugin;

impl Default for MySqlPlugin {
    fn default() -> Self {
        Self::new()
    }
}

impl MySqlPlugin {
    pub fn new() -> Self {
        Self
    }
}

impl DriverPlugin for MySqlPlugin {
    fn name(&self) -> &str {
        "mysql"
    }

    fn get_capabilities(&self) -> DriverCapabilities {
        DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 1000,
            driver_name: "MySQL".to_string(),
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
    fn test_mysql_plugin_new() {
        let plugin = MySqlPlugin::new();
        assert_eq!(plugin.name(), "mysql");
    }

    #[test]
    fn test_mysql_plugin_default() {
        let plugin = MySqlPlugin::default();
        assert_eq!(plugin.name(), "mysql");
    }

    #[test]
    fn test_mysql_plugin_name() {
        let plugin = MySqlPlugin::new();
        assert_eq!(plugin.name(), "mysql");
    }

    #[test]
    fn test_mysql_plugin_capabilities() {
        let plugin = MySqlPlugin::new();
        let caps = plugin.get_capabilities();

        assert!(caps.supports_prepared_statements);
        assert!(caps.supports_batch_operations);
        assert!(caps.supports_streaming);
        assert!(caps.supports_array_fetch);
        assert_eq!(caps.max_row_array_size, 1000);
        assert_eq!(caps.driver_name, "MySQL");
        assert_eq!(caps.driver_version, "Unknown");
    }

    #[test]
    fn test_mysql_plugin_map_type() {
        let plugin = MySqlPlugin::new();

        assert_eq!(plugin.map_type(1), OdbcType::Varchar);
        assert_eq!(plugin.map_type(4), OdbcType::Integer);
        assert_eq!(plugin.map_type(-5), OdbcType::BigInt);
        assert_eq!(plugin.map_type(3), OdbcType::Decimal);
        assert_eq!(plugin.map_type(9), OdbcType::Date);
        assert_eq!(plugin.map_type(11), OdbcType::Timestamp);
        assert_eq!(plugin.map_type(-2), OdbcType::Binary);
        assert_eq!(plugin.map_type(99), OdbcType::Varchar);
    }

    #[test]
    fn test_mysql_plugin_optimize_query_select_without_limit() {
        let plugin = MySqlPlugin::new();

        let sql = "SELECT * FROM users";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 1000");
    }

    #[test]
    fn test_mysql_plugin_optimize_query_select_with_semicolon() {
        let plugin = MySqlPlugin::new();

        let sql = "SELECT * FROM users;";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 1000;");
    }

    #[test]
    fn test_mysql_plugin_optimize_query_already_has_limit() {
        let plugin = MySqlPlugin::new();

        let sql = "SELECT * FROM users LIMIT 500";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 500");
    }

    #[test]
    fn test_mysql_plugin_optimize_query_with_where() {
        let plugin = MySqlPlugin::new();

        let sql = "SELECT * FROM users WHERE id > 10";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users WHERE id > 10");
    }

    #[test]
    fn test_mysql_plugin_optimize_query_with_order_by() {
        let plugin = MySqlPlugin::new();

        let sql = "SELECT * FROM users ORDER BY name";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users ORDER BY name");
    }

    #[test]
    fn test_mysql_plugin_get_optimization_rules() {
        let plugin = MySqlPlugin::new();
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

    #[test]
    fn test_mysql_plugin_optimize_query_insert() {
        let plugin = MySqlPlugin::new();

        let sql = "INSERT INTO users (name, email) VALUES ('John', 'john@example.com')";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(
            optimized,
            "INSERT INTO users (name, email) VALUES ('John', 'john@example.com')"
        );
    }

    #[test]
    fn test_mysql_plugin_optimize_query_update() {
        let plugin = MySqlPlugin::new();

        let sql = "UPDATE users SET name = 'Jane' WHERE id = 1";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "UPDATE users SET name = 'Jane' WHERE id = 1");
    }

    #[test]
    fn test_mysql_plugin_optimize_query_delete() {
        let plugin = MySqlPlugin::new();

        let sql = "DELETE FROM users WHERE id = 1";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "DELETE FROM users WHERE id = 1");
    }
}

use crate::engine::core::DriverCapabilities as CoreDriverCapabilities;
use crate::protocol::types::OdbcType;

pub trait DriverPlugin: Send + Sync {
    fn name(&self) -> &str;

    fn get_capabilities(&self) -> DriverCapabilities;

    fn map_type(&self, odbc_type: i16) -> OdbcType;

    fn optimize_query(&self, sql: &str) -> String;

    fn get_optimization_rules(&self) -> Vec<OptimizationRule>;
}

#[derive(Debug, Clone)]
pub struct DriverCapabilities {
    pub supports_prepared_statements: bool,
    pub supports_batch_operations: bool,
    pub supports_streaming: bool,
    pub supports_array_fetch: bool,
    pub max_row_array_size: u32,
    pub driver_name: String,
    pub driver_version: String,
}

impl From<CoreDriverCapabilities> for DriverCapabilities {
    fn from(core: CoreDriverCapabilities) -> Self {
        Self {
            supports_prepared_statements: core.supports_prepared_statements,
            supports_batch_operations: core.supports_batch_operations,
            supports_streaming: core.supports_streaming,
            supports_array_fetch: false,
            max_row_array_size: core.max_row_array_size,
            driver_name: core.driver_name,
            driver_version: core.driver_version,
        }
    }
}

#[derive(Debug, Clone)]
pub enum OptimizationRule {
    UsePreparedStatements,
    UseBatchOperations,
    UseArrayFetch {
        size: u32,
    },
    RewriteQuery {
        pattern: String,
        replacement: String,
    },
    EnableStreaming,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_driver_capabilities_from_core() {
        let core = CoreDriverCapabilities::default();
        let cap: DriverCapabilities = core.into();
        assert!(cap.supports_prepared_statements);
        assert!(cap.supports_batch_operations);
        assert!(cap.supports_streaming);
        assert!(!cap.supports_array_fetch);
        assert_eq!(cap.max_row_array_size, 1000);
        assert_eq!(cap.driver_name, "Unknown");
        assert_eq!(cap.driver_version, "Unknown");
    }

    #[test]
    fn test_driver_capabilities_debug_clone() {
        let cap = DriverCapabilities {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            supports_array_fetch: true,
            max_row_array_size: 500,
            driver_name: "Test".to_string(),
            driver_version: "1.0".to_string(),
        };
        let c2 = cap.clone();
        assert_eq!(cap.max_row_array_size, c2.max_row_array_size);
        assert!(format!("{:?}", cap).contains("DriverCapabilities"));
    }

    #[test]
    fn test_optimization_rule_variants() {
        let _r1 = OptimizationRule::UsePreparedStatements;
        let _r2 = OptimizationRule::UseBatchOperations;
        let _r3 = OptimizationRule::UseArrayFetch { size: 1000 };
        let _r4 = OptimizationRule::RewriteQuery {
            pattern: "x".to_string(),
            replacement: "y".to_string(),
        };
        let _r5 = OptimizationRule::EnableStreaming;
        assert!(matches!(
            OptimizationRule::UsePreparedStatements,
            OptimizationRule::UsePreparedStatements
        ));
        assert!(matches!(
            OptimizationRule::UseArrayFetch { size: 500 },
            OptimizationRule::UseArrayFetch { size: 500 }
        ));
    }

    struct TestDriverPlugin;

    impl DriverPlugin for TestDriverPlugin {
        fn name(&self) -> &str {
            "TestDriver"
        }

        fn get_capabilities(&self) -> DriverCapabilities {
            DriverCapabilities {
                supports_prepared_statements: true,
                supports_batch_operations: true,
                supports_streaming: true,
                supports_array_fetch: false,
                max_row_array_size: 1000,
                driver_name: "TestDriver".to_string(),
                driver_version: "1.0".to_string(),
            }
        }

        fn map_type(&self, odbc_type: i16) -> OdbcType {
            match odbc_type {
                1 => OdbcType::Varchar,
                2 => OdbcType::Integer,
                3 => OdbcType::BigInt,
                _ => OdbcType::Varchar,
            }
        }

        fn optimize_query(&self, sql: &str) -> String {
            sql.trim().to_string()
        }

        fn get_optimization_rules(&self) -> Vec<OptimizationRule> {
            vec![
                OptimizationRule::UsePreparedStatements,
                OptimizationRule::EnableStreaming,
            ]
        }
    }

    #[test]
    fn test_driver_plugin_trait_impl_returns_expected_values() {
        let plugin = TestDriverPlugin;
        assert_eq!(plugin.name(), "TestDriver");

        let cap = plugin.get_capabilities();
        assert!(cap.supports_prepared_statements);
        assert!(cap.supports_streaming);
        assert_eq!(cap.driver_name, "TestDriver");

        assert_eq!(plugin.map_type(1), OdbcType::Varchar);
        assert_eq!(plugin.map_type(2), OdbcType::Integer);
        assert_eq!(plugin.map_type(99), OdbcType::Varchar);

        let optimized = plugin.optimize_query("  SELECT 1  ");
        assert_eq!(optimized, "SELECT 1");

        let rules = plugin.get_optimization_rules();
        assert_eq!(rules.len(), 2);
        assert!(matches!(rules[0], OptimizationRule::UsePreparedStatements));
        assert!(matches!(rules[1], OptimizationRule::EnableStreaming));
    }
}

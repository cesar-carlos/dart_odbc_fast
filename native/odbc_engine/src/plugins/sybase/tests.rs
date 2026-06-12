use super::SybasePlugin;
use crate::engine::identifier::IdentifierQuoting;
use crate::plugins::capabilities::returning::DmlVerb;
use crate::plugins::capabilities::{
    CatalogProvider, IdentifierQuoter, Returnable, SessionInitializer, SessionOptions, TypeCatalog,
};
use crate::plugins::driver_plugin::{DriverPlugin, OptimizationRule};
use crate::protocol::types::OdbcType;
use crate::protocol::ParamValue;

#[test]
fn test_sybase_plugin_new() {
    let plugin = SybasePlugin::new();
    assert_eq!(plugin.name(), "sybase");
}

#[test]
fn test_sybase_plugin_default() {
    let plugin = SybasePlugin;
    assert_eq!(plugin.name(), "sybase");
}

#[test]
fn test_sybase_plugin_name() {
    let plugin = SybasePlugin::new();
    assert_eq!(plugin.name(), "sybase");
}

#[test]
fn test_sybase_plugin_capabilities() {
    let plugin = SybasePlugin::new();
    let caps = plugin.get_capabilities();

    assert!(caps.supports_prepared_statements);
    assert!(caps.supports_batch_operations);
    assert!(caps.supports_streaming);
    assert!(caps.supports_array_fetch);
    assert_eq!(caps.max_row_array_size, 500);
    assert_eq!(caps.driver_name, "Sybase");
    assert_eq!(caps.driver_version, "Unknown");
}

#[test]
fn test_sybase_plugin_map_type() {
    let plugin = SybasePlugin::new();

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
fn test_sybase_plugin_optimize_query_no_change() {
    let plugin = SybasePlugin::new();

    let sql = "SELECT * FROM users";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT * FROM users");
}

#[test]
fn test_sybase_plugin_optimize_query_preserves_original() {
    let plugin = SybasePlugin::new();

    let sql = "SELECT id, name FROM users WHERE id > 10";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT id, name FROM users WHERE id > 10");
}

#[test]
fn test_sybase_plugin_get_optimization_rules() {
    let plugin = SybasePlugin::new();
    let rules = plugin.get_optimization_rules();

    assert_eq!(rules.len(), 4);
    assert!(matches!(rules[0], OptimizationRule::UsePreparedStatements));
    assert!(matches!(rules[1], OptimizationRule::UseBatchOperations));
    assert!(matches!(
        rules[2],
        OptimizationRule::UseArrayFetch { size: 500 }
    ));
    assert!(matches!(rules[3], OptimizationRule::EnableStreaming));
}

#[test]
fn should_emit_sysobjects_list_tables_catalog_sql() {
    let plugin = SybasePlugin::new();
    let q = plugin.list_tables_sql(None, None).unwrap();
    assert!(q.sql.contains("sysobjects"));
    assert!(q.sql.contains("type IN ('U','V')"));
}

#[test]
fn session_init_sets_quoted_identifier_on() {
    let plugin = SybasePlugin::new();
    let stmts = plugin.initialization_sql(&SessionOptions::default());
    assert!(stmts.iter().any(|s| s.contains("QUOTED_IDENTIFIER ON")));
}

#[test]
fn should_emit_sybase_list_columns_catalog_sql() {
    let plugin = SybasePlugin::new();
    let q = plugin.list_columns_sql("orders", None).unwrap();
    assert!(q.sql.contains("syscolumns"));
    assert_eq!(q.params.len(), 1);
    assert!(matches!(&q.params[0], ParamValue::String(s) if s == "orders"));
}

#[test]
fn should_emit_sybase_primary_keys_catalog_sql() {
    let plugin = SybasePlugin::new();
    let q = plugin.list_primary_keys_sql("orders", None).unwrap();
    assert!(q.sql.contains("sysindexes"));
    assert!(q.sql.contains("status & 2048"));
}

#[test]
fn should_emit_sybase_foreign_keys_catalog_sql() {
    let plugin = SybasePlugin::new();
    let q = plugin.list_foreign_keys_sql("orders", None).unwrap();
    assert!(q.sql.contains("sysreferences"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn should_emit_sybase_indexes_catalog_sql() {
    let plugin = SybasePlugin::new();
    let q = plugin.list_indexes_sql("orders", None).unwrap();
    assert!(q.sql.contains("sysindexkeys"));
    assert!(q.sql.contains("indid > 0"));
}

#[test]
fn should_map_money_type_name_to_money_odbc_type() {
    let plugin = SybasePlugin::new();
    assert_eq!(plugin.map_type_extended(12, Some("money")), OdbcType::Money);
    assert_eq!(
        plugin.map_type_extended(12, Some("NVARCHAR")),
        OdbcType::NVarchar
    );
}

#[test]
fn should_use_bracket_quoting_style() {
    let plugin = SybasePlugin::new();
    assert_eq!(plugin.quoting_style(), IdentifierQuoting::Brackets);
}

#[test]
fn should_reject_returning_clause_for_sybase() {
    let plugin = SybasePlugin::new();
    let err = plugin
        .append_returning_clause("INSERT INTO t (id) VALUES (?)", DmlVerb::Insert, &["id"])
        .expect_err("no returning");
    assert!(err.to_string().contains("RETURNING"));
}

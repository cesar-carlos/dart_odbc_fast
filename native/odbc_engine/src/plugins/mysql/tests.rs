use super::MySqlPlugin;
use crate::engine::identifier::IdentifierQuoting;
use crate::error::OdbcError;
use crate::plugins::capabilities::returning::DmlVerb;
use crate::plugins::capabilities::{
    BulkLoader, CatalogProvider, IdentifierQuoter, Returnable, SessionInitializer, SessionOptions,
    TypeCatalog, Upsertable,
};
use crate::plugins::driver_plugin::{DriverPlugin, OptimizationRule};
use crate::protocol::types::OdbcType;
use crate::protocol::ParamValue;

#[test]
fn test_mysql_plugin_new() {
    let plugin = MySqlPlugin::new();
    assert_eq!(plugin.name(), "mysql");
}

#[test]
fn test_mysql_plugin_default() {
    let plugin = MySqlPlugin;
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

#[test]
fn should_build_upsert_sql_with_on_duplicate_key_update() {
    let plugin = MySqlPlugin::new();
    let sql = plugin
        .build_upsert_sql("users", &["id", "name"], &["id"], None)
        .expect("valid upsert");
    assert!(sql.contains("ON DUPLICATE KEY UPDATE"));
    assert!(sql.contains("`name` = VALUES(`name`)"));
}

#[test]
fn should_quote_identifiers_with_backticks() {
    let plugin = MySqlPlugin::new();
    assert_eq!(plugin.quote("order").unwrap(), "`order`");
}

#[test]
#[allow(
    clippy::default_constructed_unit_structs,
    reason = "intentional: exercises the impl Default for MySqlPlugin"
)]
fn default_constructor_should_produce_named_plugin() {
    let plugin = MySqlPlugin::default();
    assert_eq!(plugin.name(), "mysql");
}

#[test]
fn bulk_loader_should_advertise_array_binding_technique() {
    let plugin = MySqlPlugin::new();
    assert_eq!(plugin.technique(), "array_binding_optimised");
    assert!(plugin.supports_native_bulk());
}

#[test]
fn returnable_should_be_unsupported_with_explanatory_error() {
    let plugin = MySqlPlugin::new();
    assert!(!plugin.supports_returning());
    let err = plugin
        .append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["a"])
        .unwrap_err();
    match err {
        OdbcError::UnsupportedFeature(msg) => {
            assert!(msg.contains("RETURNING"));
            assert!(msg.contains("LAST_INSERT_ID"));
        }
        other => panic!("expected UnsupportedFeature, got {other:?}"),
    }
}

#[test]
fn upsert_should_reject_when_every_column_is_a_conflict_column() {
    let plugin = MySqlPlugin::new();
    let err = plugin
        .build_upsert_sql("t", &["id"], &["id"], None)
        .unwrap_err();
    match err {
        OdbcError::ValidationError(msg) => {
            assert!(msg.contains("at least one column to update"));
        }
        other => panic!("expected ValidationError, got {other:?}"),
    }
}

#[test]
fn type_catalog_should_map_json_by_type_name() {
    let plugin = MySqlPlugin::new();
    assert_eq!(plugin.map_type_extended(1, Some("json")), OdbcType::Json);
}

#[test]
fn type_catalog_should_map_tinyint_one_as_boolean() {
    let plugin = MySqlPlugin::new();
    assert_eq!(
        plugin.map_type_extended(4, Some("tinyint(1)")),
        OdbcType::Boolean,
    );
    assert_eq!(
        plugin.map_type_extended(4, Some("boolean")),
        OdbcType::Boolean,
    );
    assert_eq!(plugin.map_type_extended(4, Some("bool")), OdbcType::Boolean);
}

#[test]
fn type_catalog_should_map_numeric_aliases() {
    let plugin = MySqlPlugin::new();
    assert_eq!(
        plugin.map_type_extended(0, Some("smallint")),
        OdbcType::SmallInt,
    );
    assert_eq!(plugin.map_type_extended(0, Some("float")), OdbcType::Float);
    assert_eq!(
        plugin.map_type_extended(0, Some("double")),
        OdbcType::Double
    );
    assert_eq!(plugin.map_type_extended(0, Some("real")), OdbcType::Double);
}

#[test]
fn type_catalog_should_map_blob_family_as_binary() {
    let plugin = MySqlPlugin::new();
    for name in &["blob", "tinyblob", "mediumblob", "longblob", "varbinary"] {
        assert_eq!(plugin.map_type_extended(0, Some(name)), OdbcType::Binary);
    }
}

#[test]
fn type_catalog_should_fall_back_to_map_type_when_name_unrecognised() {
    let plugin = MySqlPlugin::new();
    // type_name is unknown — should defer to map_type(1) => Varchar
    assert_eq!(
        plugin.map_type_extended(1, Some("not_a_real_type")),
        OdbcType::Varchar,
    );
    // type_name absent — same fallback
    assert_eq!(plugin.map_type_extended(4, None), OdbcType::Integer);
}

#[test]
fn catalog_provider_should_build_primary_key_query_with_table_param() {
    let plugin = MySqlPlugin::new();
    let q = plugin
        .list_primary_keys_sql("users", None)
        .expect("valid catalog query");
    assert!(q.sql.contains("INFORMATION_SCHEMA.KEY_COLUMN_USAGE"));
    assert!(q.sql.contains("CONSTRAINT_NAME = 'PRIMARY'"));
    assert_eq!(q.params.len(), 1);
    assert!(matches!(&q.params[0], ParamValue::String(s) if s == "users"));
}

#[test]
fn catalog_provider_should_build_foreign_key_query_with_table_param() {
    let plugin = MySqlPlugin::new();
    let q = plugin
        .list_foreign_keys_sql("orders", None)
        .expect("valid catalog query");
    assert!(q.sql.contains("REFERENCED_TABLE_NAME IS NOT NULL"));
    assert_eq!(q.params.len(), 1);
    assert!(matches!(&q.params[0], ParamValue::String(s) if s == "orders"));
}

#[test]
fn catalog_provider_should_build_index_query_with_table_param() {
    let plugin = MySqlPlugin::new();
    let q = plugin
        .list_indexes_sql("users", None)
        .expect("valid catalog query");
    assert!(q.sql.contains("INFORMATION_SCHEMA.STATISTICS"));
    assert!(q.sql.contains("SEQ_IN_INDEX"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn session_initializer_should_default_to_utf8mb4_charset() {
    let plugin = MySqlPlugin::new();
    let stmts = plugin.initialization_sql(&SessionOptions::default());
    assert!(stmts.iter().any(|s| s == "SET NAMES utf8mb4"));
}

#[test]
fn session_initializer_should_emit_timezone_when_provided() {
    let plugin = MySqlPlugin::new();
    let opts = SessionOptions {
        timezone: Some("UTC".to_string()),
        ..Default::default()
    };
    let stmts = plugin.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s.contains("SET time_zone = 'UTC'")));
}

#[test]
fn session_initializer_should_escape_single_quotes_in_timezone() {
    let plugin = MySqlPlugin::new();
    let opts = SessionOptions {
        timezone: Some("America/Sao_Paulo'; DROP".to_string()),
        ..Default::default()
    };
    let stmts = plugin.initialization_sql(&opts);
    let tz_stmt = stmts
        .iter()
        .find(|s| s.starts_with("SET time_zone"))
        .expect("timezone statement emitted");
    // Single quote in payload should be doubled, never closed prematurely.
    assert!(tz_stmt.contains("America/Sao_Paulo''; DROP"));
}

#[test]
fn session_initializer_should_emit_use_statement_for_schema() {
    let plugin = MySqlPlugin::new();
    let opts = SessionOptions {
        schema: Some("app_db".to_string()),
        ..Default::default()
    };
    let stmts = plugin.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s == "USE `app_db`"));
}

#[test]
fn session_initializer_should_append_extra_sql_verbatim() {
    let plugin = MySqlPlugin::new();
    let opts = SessionOptions {
        extra_sql: vec!["SET sql_mode = 'STRICT_ALL_TABLES'".to_string()],
        ..Default::default()
    };
    let stmts = plugin.initialization_sql(&opts);
    assert!(stmts
        .iter()
        .any(|s| s == "SET sql_mode = 'STRICT_ALL_TABLES'"));
}

#[test]
fn identifier_quoter_should_use_backtick_style() {
    let plugin = MySqlPlugin::new();
    assert_eq!(plugin.quoting_style(), IdentifierQuoting::Backtick);
}

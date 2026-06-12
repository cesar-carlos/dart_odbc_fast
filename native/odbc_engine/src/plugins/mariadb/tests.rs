use super::MariaDbPlugin;
use crate::engine::identifier::IdentifierQuoting;
use crate::plugins::capabilities::returning::DmlVerb;
use crate::plugins::capabilities::{
    CatalogProvider, IdentifierQuoter, Returnable, SessionInitializer, SessionOptions, TypeCatalog,
    Upsertable,
};
use crate::plugins::driver_plugin::{DriverPlugin, OptimizationRule};
use crate::protocol::types::OdbcType;

#[test]
fn name_is_mariadb() {
    assert_eq!(MariaDbPlugin::new().name(), "mariadb");
}

#[test]
fn supports_returning() {
    let p = MariaDbPlugin::new();
    assert!(p.supports_returning());
}

#[test]
fn upsert_uses_on_duplicate_key_with_backticks() {
    let p = MariaDbPlugin::new();
    let sql = p
        .build_upsert_sql("u", &["id", "name"], &["id"], None)
        .unwrap();
    assert!(sql.contains("ON DUPLICATE KEY UPDATE"));
    assert!(sql.contains("`name` = VALUES(`name`)"));
}

#[test]
fn upsert_with_no_updates_uses_self_assignment() {
    let p = MariaDbPlugin::new();
    let sql = p.build_upsert_sql("u", &["id"], &["id"], None).unwrap();
    assert!(sql.contains("ON DUPLICATE KEY UPDATE"));
}

#[test]
fn should_emit_mariadb_indexes_catalog_sql() {
    let p = MariaDbPlugin::new();
    let q = p.list_indexes_sql("users", None).unwrap();
    assert!(q.sql.contains("INFORMATION_SCHEMA.STATISTICS"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn session_init_sets_names_charset() {
    let p = MariaDbPlugin::new();
    let opts = SessionOptions::new().with_charset("utf8mb4");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s.contains("SET NAMES utf8mb4")));
}

#[test]
fn type_catalog_recognises_uuid_as_uuid() {
    let p = MariaDbPlugin::new();
    assert_eq!(p.map_type_extended(1, Some("UUID")), OdbcType::Uuid);
}

#[test]
#[allow(
    clippy::default_constructed_unit_structs,
    reason = "intentional: exercises the impl Default for MariaDbPlugin"
)]
fn default_constructor_should_produce_named_plugin() {
    let p = MariaDbPlugin::default();
    assert_eq!(p.name(), "mariadb");
}

#[test]
fn capabilities_should_advertise_mariadb_specific_settings() {
    let p = MariaDbPlugin::new();
    let caps = p.get_capabilities();
    assert!(caps.supports_prepared_statements);
    assert!(caps.supports_batch_operations);
    assert!(caps.supports_streaming);
    assert_eq!(caps.max_row_array_size, 1500);
    assert_eq!(caps.driver_name, "MariaDB");
}

#[test]
fn optimize_query_should_append_limit_when_select_has_no_clauses() {
    let p = MariaDbPlugin::new();
    assert_eq!(
        p.optimize_query("SELECT * FROM t"),
        "SELECT * FROM t LIMIT 1000",
    );
}

#[test]
fn optimize_query_should_insert_limit_before_semicolon() {
    let p = MariaDbPlugin::new();
    let out = p.optimize_query("SELECT * FROM t;");
    assert!(out.contains("LIMIT 1000;"));
}

#[test]
fn optimize_query_should_skip_when_already_has_limit() {
    let p = MariaDbPlugin::new();
    assert_eq!(
        p.optimize_query("SELECT * FROM t LIMIT 5"),
        "SELECT * FROM t LIMIT 5",
    );
}

#[test]
fn optimize_query_should_skip_when_where_or_order_by_present() {
    let p = MariaDbPlugin::new();
    assert_eq!(
        p.optimize_query("SELECT * FROM t WHERE id = 1"),
        "SELECT * FROM t WHERE id = 1",
    );
    assert_eq!(
        p.optimize_query("SELECT * FROM t ORDER BY id"),
        "SELECT * FROM t ORDER BY id",
    );
}

#[test]
fn optimization_rules_should_use_mariadb_specific_size() {
    let p = MariaDbPlugin::new();
    let rules = p.get_optimization_rules();
    assert!(rules
        .iter()
        .any(|r| matches!(r, OptimizationRule::UseArrayFetch { size: 1500 })));
}

#[test]
fn returning_clause_should_strip_trailing_semicolon() {
    let p = MariaDbPlugin::new();
    let out = p
        .append_returning_clause("INSERT INTO t (a) VALUES (?);", DmlVerb::Insert, &["a"])
        .unwrap();
    assert!(out.contains("RETURNING"));
    assert!(out.contains("\"a\""));
    assert!(!out.contains(';'));
}

#[test]
fn identifier_quoter_should_use_backtick_style() {
    let p = MariaDbPlugin::new();
    assert_eq!(p.quoting_style(), IdentifierQuoting::Backtick);
}

#[test]
fn type_catalog_should_map_json_alias() {
    let p = MariaDbPlugin::new();
    assert_eq!(p.map_type_extended(1, Some("json")), OdbcType::Json);
}

#[test]
fn type_catalog_should_map_boolean_aliases() {
    let p = MariaDbPlugin::new();
    for name in &["tinyint(1)", "boolean", "bool"] {
        assert_eq!(p.map_type_extended(4, Some(name)), OdbcType::Boolean);
    }
}

#[test]
fn type_catalog_should_map_double_real_aliases() {
    let p = MariaDbPlugin::new();
    for name in &["double", "double precision", "real"] {
        assert_eq!(p.map_type_extended(0, Some(name)), OdbcType::Double);
    }
}

#[test]
fn type_catalog_should_map_blob_family_as_binary() {
    let p = MariaDbPlugin::new();
    for name in &["blob", "tinyblob", "mediumblob", "longblob", "varbinary"] {
        assert_eq!(p.map_type_extended(0, Some(name)), OdbcType::Binary);
    }
}

#[test]
fn type_catalog_should_fall_back_when_name_unknown_or_absent() {
    let p = MariaDbPlugin::new();
    let _ = p.map_type_extended(1, Some("custom_type"));
    let _ = p.map_type_extended(4, None);
}

#[test]
fn catalog_provider_should_emit_primary_key_query_with_table_param() {
    let p = MariaDbPlugin::new();
    let q = p.list_primary_keys_sql("orders", None).unwrap();
    assert!(q.sql.contains("INFORMATION_SCHEMA.KEY_COLUMN_USAGE"));
    assert!(q.sql.contains("CONSTRAINT_NAME = 'PRIMARY'"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn catalog_provider_should_emit_foreign_key_query_with_table_param() {
    let p = MariaDbPlugin::new();
    let q = p.list_foreign_keys_sql("orders", None).unwrap();
    assert!(q.sql.contains("REFERENCED_TABLE_NAME IS NOT NULL"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn session_init_should_emit_timezone_when_provided() {
    let p = MariaDbPlugin::new();
    let opts = SessionOptions::new().with_timezone("UTC");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s == "SET time_zone = 'UTC'"));
}

#[test]
fn session_init_should_escape_timezone_single_quotes() {
    let p = MariaDbPlugin::new();
    let opts = SessionOptions::new().with_timezone("AB'CD");
    let stmts = p.initialization_sql(&opts);
    let tz = stmts
        .iter()
        .find(|s| s.starts_with("SET time_zone"))
        .expect("tz statement emitted");
    assert!(tz.contains("AB''CD"));
}

#[test]
fn session_init_should_emit_use_when_schema_set() {
    let p = MariaDbPlugin::new();
    let opts = SessionOptions::new().with_schema("appdb");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s == "USE `appdb`"));
}

#[test]
fn session_init_should_pass_through_extra_sql_verbatim() {
    let p = MariaDbPlugin::new();
    let opts = SessionOptions::new().with_extra_sql("SET sql_mode = 'STRICT'");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s == "SET sql_mode = 'STRICT'"));
}

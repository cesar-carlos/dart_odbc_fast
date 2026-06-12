use super::PostgresPlugin;
use crate::engine::identifier::IdentifierQuoting;
use crate::plugins::capabilities::returning::DmlVerb;
use crate::plugins::capabilities::{
    BulkLoader, CatalogProvider, IdentifierQuoter, Returnable, SessionInitializer, SessionOptions,
    TypeCatalog, Upsertable,
};
use crate::plugins::driver_plugin::{DriverPlugin, OptimizationRule};
use crate::protocol::types::OdbcType;
use crate::protocol::ParamValue;

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

#[test]
fn should_build_upsert_sql_with_on_conflict_update() {
    let plugin = PostgresPlugin::new();
    let sql = plugin
        .build_upsert_sql("public.users", &["id", "name"], &["id"], None)
        .expect("valid upsert");
    assert!(sql.contains("INSERT INTO"));
    assert!(sql.contains("ON CONFLICT"));
    assert!(sql.contains("DO UPDATE SET"));
    assert!(sql.contains("EXCLUDED.\"name\""));
}

#[test]
fn should_quote_identifiers_with_double_quotes() {
    let plugin = PostgresPlugin::new();
    assert_eq!(plugin.quote("UserName").unwrap(), "\"UserName\"");
}

#[test]
fn should_append_returning_clause() {
    let plugin = PostgresPlugin::new();
    let sql = plugin
        .append_returning_clause("INSERT INTO t (id) VALUES (?)", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(sql.ends_with("RETURNING \"id\""));
}

#[test]
fn should_emit_pg_indexes_catalog_sql() {
    let plugin = PostgresPlugin::new();
    let q = plugin.list_indexes_sql("users", None).unwrap();
    assert!(q.sql.contains("pg_indexes"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn session_init_quotes_search_path_schema() {
    let plugin = PostgresPlugin::new();
    let opts = SessionOptions::new().with_schema("public");
    let stmts = plugin.initialization_sql(&opts);
    assert!(stmts
        .iter()
        .any(|s| s.contains("search_path TO \"public\"")));
}

#[test]
#[allow(
    clippy::default_constructed_unit_structs,
    reason = "intentional: exercises the impl Default for PostgresPlugin"
)]
fn default_constructor_should_produce_named_plugin() {
    let plugin = PostgresPlugin::default();
    assert_eq!(plugin.name(), "postgres");
}

#[test]
fn bulk_loader_should_advertise_array_binding_technique() {
    let plugin = PostgresPlugin::new();
    assert_eq!(plugin.technique(), "array_binding_optimised");
    assert!(plugin.supports_native_bulk());
}

#[test]
fn upsert_should_degrade_to_do_nothing_when_no_columns_to_update() {
    let plugin = PostgresPlugin::new();
    let sql = plugin
        .build_upsert_sql("public.users", &["id"], &["id"], None)
        .expect("valid upsert");
    assert!(sql.contains("ON CONFLICT (\"id\") DO NOTHING"));
    assert!(!sql.contains("DO UPDATE"));
}

#[test]
fn returnable_should_be_supported() {
    let plugin = PostgresPlugin::new();
    assert!(plugin.supports_returning());
}

#[test]
fn returning_clause_should_strip_trailing_semicolon() {
    let plugin = PostgresPlugin::new();
    let sql = plugin
        .append_returning_clause("INSERT INTO t (id) VALUES (?);", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(sql.ends_with("RETURNING \"id\""));
    assert!(!sql.contains(";"));
}

#[test]
fn type_catalog_should_map_json_and_jsonb_to_json() {
    let plugin = PostgresPlugin::new();
    assert_eq!(plugin.map_type_extended(1, Some("json")), OdbcType::Json);
    assert_eq!(plugin.map_type_extended(1, Some("jsonb")), OdbcType::Json);
}

#[test]
fn type_catalog_should_map_uuid_and_bytea() {
    let plugin = PostgresPlugin::new();
    assert_eq!(plugin.map_type_extended(1, Some("uuid")), OdbcType::Uuid);
    assert_eq!(plugin.map_type_extended(1, Some("bytea")), OdbcType::Binary);
}

#[test]
fn type_catalog_should_map_timestamptz_to_timestamp_with_tz() {
    let plugin = PostgresPlugin::new();
    assert_eq!(
        plugin.map_type_extended(11, Some("timestamptz")),
        OdbcType::TimestampWithTz,
    );
    assert_eq!(
        plugin.map_type_extended(11, Some("timestamp with time zone")),
        OdbcType::TimestampWithTz,
    );
}

#[test]
fn type_catalog_should_map_pg_numeric_aliases() {
    let plugin = PostgresPlugin::new();
    assert_eq!(
        plugin.map_type_extended(0, Some("int2")),
        OdbcType::SmallInt
    );
    assert_eq!(plugin.map_type_extended(0, Some("float4")), OdbcType::Float);
    assert_eq!(plugin.map_type_extended(0, Some("real")), OdbcType::Float);
    assert_eq!(
        plugin.map_type_extended(0, Some("float8")),
        OdbcType::Double
    );
    assert_eq!(
        plugin.map_type_extended(0, Some("double precision")),
        OdbcType::Double,
    );
}

#[test]
fn type_catalog_should_fall_back_when_type_name_is_unknown() {
    let plugin = PostgresPlugin::new();
    assert_eq!(
        plugin.map_type_extended(1, Some("custom_type")),
        OdbcType::Varchar,
    );
    assert_eq!(plugin.map_type_extended(4, None), OdbcType::Integer);
}

#[test]
fn identifier_quoter_should_use_double_quote_style() {
    let plugin = PostgresPlugin::new();
    assert_eq!(plugin.quoting_style(), IdentifierQuoting::DoubleQuote);
}

#[test]
fn catalog_provider_should_emit_primary_key_query_with_table_param() {
    let plugin = PostgresPlugin::new();
    let q = plugin
        .list_primary_keys_sql("orders", None)
        .expect("valid catalog query");
    assert!(q.sql.contains("constraint_type = 'PRIMARY KEY'"));
    assert_eq!(q.params.len(), 1);
    assert!(matches!(&q.params[0], ParamValue::String(s) if s == "orders"));
}

#[test]
fn catalog_provider_should_emit_foreign_key_query_joining_ccu() {
    let plugin = PostgresPlugin::new();
    let q = plugin
        .list_foreign_keys_sql("orders", None)
        .expect("valid catalog query");
    assert!(q.sql.contains("constraint_type = 'FOREIGN KEY'"));
    assert!(q.sql.contains("constraint_column_usage"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn session_init_should_emit_application_name_with_escaped_quotes() {
    let plugin = PostgresPlugin::new();
    let opts = SessionOptions::new().with_application_name("svc'name");
    let stmts = plugin.initialization_sql(&opts);
    let app_stmt = stmts
        .iter()
        .find(|s| s.starts_with("SET application_name"))
        .expect("application_name statement emitted");
    assert!(app_stmt.contains("'svc''name'"));
}

#[test]
fn session_init_should_emit_time_zone_with_escaped_quotes() {
    let plugin = PostgresPlugin::new();
    let opts = SessionOptions::new().with_timezone("Etc/UTC");
    let stmts = plugin.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s == "SET TIME ZONE 'Etc/UTC'"));
}

#[test]
fn session_init_should_pass_through_extra_sql_verbatim() {
    let plugin = PostgresPlugin::new();
    let opts = SessionOptions::new().with_extra_sql("SET statement_timeout = 5000");
    let stmts = plugin.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s == "SET statement_timeout = 5000"));
}

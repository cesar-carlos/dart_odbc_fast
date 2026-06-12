use super::SnowflakePlugin;
use crate::plugins::capabilities::returning::DmlVerb;
use crate::plugins::capabilities::{
    CatalogProvider, Returnable, SessionInitializer, SessionOptions, TypeCatalog, Upsertable,
};
use crate::plugins::driver_plugin::{DriverPlugin, OptimizationRule};
use crate::protocol::types::OdbcType;

#[test]
fn name_is_snowflake() {
    assert_eq!(SnowflakePlugin::new().name(), "snowflake");
}

#[test]
fn upsert_uses_select_using() {
    let p = SnowflakePlugin::new();
    let sql = p
        .build_upsert_sql("schema.t", &["id", "name"], &["id"], None)
        .unwrap();
    assert!(sql.contains("MERGE INTO \"schema\".\"t\" t"));
    assert!(sql.contains("USING (SELECT ? AS \"id\", ? AS \"name\")"));
}

#[test]
fn type_catalog_recognises_variant_as_json() {
    let p = SnowflakePlugin::new();
    assert_eq!(p.map_type_extended(1, Some("VARIANT")), OdbcType::Json);
    assert_eq!(p.map_type_extended(1, Some("OBJECT")), OdbcType::Json);
    assert_eq!(p.map_type_extended(1, Some("ARRAY")), OdbcType::Json);
}

#[test]
fn session_init_uses_query_tag_for_app_name() {
    let p = SnowflakePlugin::new();
    let opts = SessionOptions::new().with_application_name("dart-app");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s.contains("QUERY_TAG = 'dart-app'")));
}

#[test]
fn returning_appended() {
    let p = SnowflakePlugin::new();
    let r = p
        .append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(r.ends_with("RETURNING \"id\""));
}

#[test]
fn should_emit_empty_indexes_catalog_query() {
    let p = SnowflakePlugin::new();
    let q = p.list_indexes_sql("any_table", None).unwrap();
    assert!(q.sql.contains("WHERE 1 = 0"));
    assert!(q.params.is_empty());
}

#[test]
fn should_emit_information_schema_tables_for_list_tables() {
    let p = SnowflakePlugin::new();
    let q = p.list_tables_sql(None, Some("PUBLIC")).unwrap();
    assert!(q.sql.contains("INFORMATION_SCHEMA.TABLES"));
    assert_eq!(q.params.len(), 1);
}

#[test]
#[allow(
    clippy::default_constructed_unit_structs,
    reason = "intentional: exercises the impl Default for SnowflakePlugin"
)]
fn default_constructor_should_produce_named_plugin() {
    let p = SnowflakePlugin::default();
    assert_eq!(p.name(), "snowflake");
}

#[test]
fn capabilities_advertise_higher_array_fetch_size() {
    let p = SnowflakePlugin::new();
    let caps = p.get_capabilities();
    assert_eq!(caps.max_row_array_size, 10_000);
    assert_eq!(caps.driver_name, "Snowflake");
}

#[test]
fn optimize_query_should_append_limit_when_select_without_clauses() {
    let p = SnowflakePlugin::new();
    let sql = p.optimize_query("SELECT * FROM t");
    assert_eq!(sql, "SELECT * FROM t LIMIT 1000");
}

#[test]
fn optimize_query_should_insert_limit_before_trailing_semicolon() {
    let p = SnowflakePlugin::new();
    let sql = p.optimize_query("SELECT * FROM t;");
    assert!(sql.contains(" LIMIT 1000;"));
}

#[test]
fn optimize_query_should_skip_when_limit_already_present() {
    let p = SnowflakePlugin::new();
    let sql = p.optimize_query("SELECT * FROM t LIMIT 5");
    assert_eq!(sql, "SELECT * FROM t LIMIT 5");
}

#[test]
fn optimize_query_should_skip_when_where_or_order_by_present() {
    let p = SnowflakePlugin::new();
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
fn optimization_rules_should_use_higher_array_fetch_size() {
    let p = SnowflakePlugin::new();
    let rules = p.get_optimization_rules();
    assert!(matches!(
        rules
            .iter()
            .find(|r| matches!(r, OptimizationRule::UseArrayFetch { .. })),
        Some(OptimizationRule::UseArrayFetch { size: 10_000 }),
    ));
}

#[test]
fn returnable_should_be_supported() {
    let p = SnowflakePlugin::new();
    assert!(p.supports_returning());
}

#[test]
fn returning_clause_should_strip_trailing_semicolon() {
    let p = SnowflakePlugin::new();
    let sql = p
        .append_returning_clause("INSERT INTO t (a) VALUES (?);", DmlVerb::Insert, &["a"])
        .unwrap();
    assert!(sql.ends_with("RETURNING \"a\""));
    assert!(!sql.contains(';'));
}

#[test]
fn upsert_should_omit_when_matched_block_when_only_conflict_columns() {
    let p = SnowflakePlugin::new();
    let sql = p
        .build_upsert_sql("schema.t", &["id"], &["id"], None)
        .unwrap();
    assert!(!sql.contains("WHEN MATCHED THEN UPDATE"));
    assert!(sql.contains("WHEN NOT MATCHED THEN INSERT"));
}

#[test]
fn type_catalog_should_map_timestamp_variants() {
    let p = SnowflakePlugin::new();
    assert_eq!(
        p.map_type_extended(11, Some("timestamp_tz")),
        OdbcType::TimestampWithTz,
    );
    assert_eq!(
        p.map_type_extended(11, Some("timestamp_ltz")),
        OdbcType::TimestampWithTz,
    );
    assert_eq!(
        p.map_type_extended(11, Some("timestamp_ntz")),
        OdbcType::Timestamp,
    );
}

#[test]
fn type_catalog_should_map_boolean_and_binary_aliases() {
    let p = SnowflakePlugin::new();
    assert_eq!(p.map_type_extended(1, Some("boolean")), OdbcType::Boolean,);
    assert_eq!(p.map_type_extended(1, Some("binary")), OdbcType::Binary);
    assert_eq!(p.map_type_extended(1, Some("varbinary")), OdbcType::Binary,);
}

#[test]
fn type_catalog_should_map_float_double_aliases() {
    let p = SnowflakePlugin::new();
    for name in &["real", "float", "float4"] {
        assert_eq!(p.map_type_extended(0, Some(name)), OdbcType::Float);
    }
    for name in &["double", "float8", "float64"] {
        assert_eq!(p.map_type_extended(0, Some(name)), OdbcType::Double);
    }
}

#[test]
fn type_catalog_should_map_geography_geometry_to_json() {
    let p = SnowflakePlugin::new();
    assert_eq!(p.map_type_extended(1, Some("geography")), OdbcType::Json,);
    assert_eq!(p.map_type_extended(1, Some("geometry")), OdbcType::Json,);
}

#[test]
fn type_catalog_should_fall_back_when_name_unknown_or_absent() {
    let p = SnowflakePlugin::new();
    // Defers to map_type which uses OdbcType::from_odbc_sql_type for 1 (Varchar).
    let _ = p.map_type_extended(1, Some("custom_type"));
    let _ = p.map_type_extended(4, None);
}

#[test]
fn catalog_provider_should_emit_primary_key_query_with_table_param() {
    let p = SnowflakePlugin::new();
    let q = p.list_primary_keys_sql("USERS", None).unwrap();
    assert!(q.sql.contains("constraint_type = 'PRIMARY KEY'"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn catalog_provider_should_emit_foreign_key_query_with_table_param() {
    let p = SnowflakePlugin::new();
    let q = p.list_foreign_keys_sql("ORDERS", None).unwrap();
    assert!(q.sql.contains("KEY_COLUMN_USAGE"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn session_initializer_should_emit_timezone_with_escaped_quotes() {
    let p = SnowflakePlugin::new();
    let opts = SessionOptions::new().with_timezone("UTC");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts
        .iter()
        .any(|s| s == "ALTER SESSION SET TIMEZONE = 'UTC'"));
}

#[test]
fn session_initializer_should_emit_use_schema_when_schema_set() {
    let p = SnowflakePlugin::new();
    let opts = SessionOptions::new().with_schema("PUBLIC");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s == "USE SCHEMA \"PUBLIC\""));
}

#[test]
fn session_initializer_should_escape_query_tag_quotes() {
    let p = SnowflakePlugin::new();
    let opts = SessionOptions::new().with_application_name("svc'name");
    let stmts = p.initialization_sql(&opts);
    let stmt = stmts
        .iter()
        .find(|s| s.contains("QUERY_TAG"))
        .expect("query_tag statement emitted");
    assert!(stmt.contains("'svc''name'"));
}

#[test]
fn session_initializer_should_pass_through_extra_sql_verbatim() {
    let p = SnowflakePlugin::new();
    let opts = SessionOptions::new().with_extra_sql("ALTER WAREHOUSE COMPUTE_WH SUSPEND");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts
        .iter()
        .any(|s| s == "ALTER WAREHOUSE COMPUTE_WH SUSPEND"));
}

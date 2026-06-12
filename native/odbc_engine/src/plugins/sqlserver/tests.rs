use super::SqlServerPlugin;
use crate::engine::identifier::IdentifierQuoting;
use crate::plugins::capabilities::returning::DmlVerb;
use crate::plugins::capabilities::{SessionInitializer, SessionOptions};
use crate::plugins::driver_plugin::{DriverPlugin, OptimizationRule};
use crate::protocol::types::OdbcType;
use crate::protocol::ParamValue;

use super::super::capabilities::{
    CatalogProvider, IdentifierQuoter, Returnable, TypeCatalog, Upsertable,
};

#[test]
fn test_sqlserver_plugin_new() {
    let plugin = SqlServerPlugin::new();
    assert_eq!(plugin.name(), "sqlserver");
}

#[test]
fn test_sqlserver_plugin_default() {
    let plugin = SqlServerPlugin;
    assert_eq!(plugin.name(), "sqlserver");
}

#[test]
fn test_sqlserver_plugin_name() {
    let plugin = SqlServerPlugin::new();
    assert_eq!(plugin.name(), "sqlserver");
}

#[test]
fn test_sqlserver_plugin_capabilities() {
    let plugin = SqlServerPlugin::new();
    let caps = plugin.get_capabilities();

    assert!(caps.supports_prepared_statements);
    assert!(caps.supports_batch_operations);
    assert!(caps.supports_streaming);
    assert!(caps.supports_array_fetch);
    assert_eq!(caps.max_row_array_size, 1000);
    assert_eq!(caps.driver_name, "SQL Server");
    assert_eq!(caps.driver_version, "Unknown");
}

#[test]
fn test_sqlserver_plugin_map_type() {
    let plugin = SqlServerPlugin::new();

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
fn test_sqlserver_plugin_optimize_query_select_star() {
    let plugin = SqlServerPlugin::new();

    let sql = "SELECT * FROM users";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT TOP 1000 * FROM users");
}

#[test]
fn test_sqlserver_plugin_optimize_query_select_star_with_semicolon() {
    let plugin = SqlServerPlugin::new();

    let sql = "SELECT * FROM users;";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT TOP 1000 * FROM users;");
}

#[test]
fn test_sqlserver_plugin_optimize_query_already_has_top() {
    let plugin = SqlServerPlugin::new();

    let sql = "SELECT TOP 500 * FROM users";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT TOP 500 * FROM users");
}

#[test]
fn test_sqlserver_plugin_optimize_query_no_select_star() {
    let plugin = SqlServerPlugin::new();

    let sql = "SELECT id, name FROM users";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT id, name FROM users");
}

#[test]
fn test_sqlserver_plugin_get_optimization_rules() {
    let plugin = SqlServerPlugin::new();
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
fn should_build_merge_upsert_sql() {
    let plugin = SqlServerPlugin::new();
    let sql = plugin
        .build_upsert_sql("dbo.users", &["id", "name"], &["id"], None)
        .expect("valid merge upsert");
    assert!(sql.starts_with("MERGE INTO"));
    assert!(sql.contains("WHEN NOT MATCHED"));
    assert!(sql.ends_with(';'));
}

#[test]
fn should_append_output_clause_for_insert() {
    let plugin = SqlServerPlugin::new();
    let sql = plugin
        .append_returning_clause("INSERT INTO t (id) VALUES (?)", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(sql.contains("OUTPUT INSERTED.[id]"));
}

#[test]
fn should_emit_sys_primary_keys_catalog_sql() {
    let plugin = SqlServerPlugin::new();
    let q = plugin.list_primary_keys_sql("Orders", None).unwrap();
    assert!(q.sql.contains("sys.indexes"));
    assert!(q.sql.contains("is_primary_key = 1"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn should_emit_sys_indexes_catalog_sql() {
    let plugin = SqlServerPlugin::new();
    let q = plugin.list_indexes_sql("Orders", None).unwrap();
    assert!(q.sql.contains("sys.index_columns"));
    assert_eq!(q.params.len(), 1);
}

#[test]
#[allow(
    clippy::default_constructed_unit_structs,
    reason = "intentional: exercises the impl Default for SqlServerPlugin"
)]
fn default_constructor_should_produce_named_plugin() {
    let plugin = SqlServerPlugin::default();
    assert_eq!(plugin.name(), "sqlserver");
}

#[test]
fn upsert_should_omit_when_matched_block_when_only_conflict_columns() {
    let plugin = SqlServerPlugin::new();
    let sql = plugin
        .build_upsert_sql("dbo.users", &["id"], &["id"], None)
        .expect("valid merge upsert");
    assert!(sql.starts_with("MERGE INTO"));
    assert!(!sql.contains("WHEN MATCHED THEN UPDATE"));
    assert!(sql.contains("WHEN NOT MATCHED THEN INSERT"));
}

#[test]
fn returnable_should_be_supported() {
    let plugin = SqlServerPlugin::new();
    assert!(plugin.supports_returning());
}

#[test]
fn output_clause_for_delete_should_use_deleted_prefix() {
    let plugin = SqlServerPlugin::new();
    let sql = plugin
        .append_returning_clause("DELETE FROM t WHERE id = ?", DmlVerb::Delete, &["id"])
        .unwrap();
    assert!(sql.contains("OUTPUT DELETED.[id]"));
    assert!(sql.contains("WHERE id = ?"));
}

#[test]
fn output_clause_for_delete_without_where_should_append_at_end() {
    let plugin = SqlServerPlugin::new();
    let sql = plugin
        .append_returning_clause("DELETE FROM t", DmlVerb::Delete, &["id"])
        .unwrap();
    assert!(sql.ends_with("OUTPUT DELETED.[id]"));
}

#[test]
fn output_clause_for_update_should_inject_before_where() {
    let plugin = SqlServerPlugin::new();
    let sql = plugin
        .append_returning_clause(
            "UPDATE t SET name = ? WHERE id = ?",
            DmlVerb::Update,
            &["id"],
        )
        .unwrap();
    assert!(sql.contains("OUTPUT INSERTED.[id]"));
    assert!(sql.contains("WHERE id = ?"));
}

#[test]
fn output_clause_for_update_without_where_should_append_at_end() {
    let plugin = SqlServerPlugin::new();
    let sql = plugin
        .append_returning_clause("UPDATE t SET name = ?", DmlVerb::Update, &["id"])
        .unwrap();
    assert!(sql.contains("OUTPUT INSERTED.[id]"));
}

#[test]
fn output_clause_should_strip_trailing_semicolon() {
    let plugin = SqlServerPlugin::new();
    let sql = plugin
        .append_returning_clause("INSERT INTO t (id) VALUES (?);", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(!sql.contains(';'));
}

#[test]
fn identifier_quoter_should_use_brackets_style() {
    let plugin = SqlServerPlugin::new();
    assert_eq!(plugin.quoting_style(), IdentifierQuoting::Brackets);
}

#[test]
fn type_catalog_should_map_unicode_string_aliases() {
    let plugin = SqlServerPlugin::new();
    assert_eq!(
        plugin.map_type_extended(1, Some("nvarchar")),
        OdbcType::NVarchar,
    );
    assert_eq!(
        plugin.map_type_extended(1, Some("nchar")),
        OdbcType::NVarchar,
    );
    assert_eq!(
        plugin.map_type_extended(1, Some("ntext")),
        OdbcType::NVarchar
    );
}

#[test]
fn type_catalog_should_map_datetimeoffset_and_uniqueidentifier() {
    let plugin = SqlServerPlugin::new();
    assert_eq!(
        plugin.map_type_extended(11, Some("datetimeoffset")),
        OdbcType::DatetimeOffset,
    );
    assert_eq!(
        plugin.map_type_extended(1, Some("uniqueidentifier")),
        OdbcType::Uuid,
    );
}

#[test]
fn type_catalog_should_map_money_smallmoney_to_money() {
    let plugin = SqlServerPlugin::new();
    assert_eq!(plugin.map_type_extended(3, Some("money")), OdbcType::Money);
    assert_eq!(
        plugin.map_type_extended(3, Some("smallmoney")),
        OdbcType::Money,
    );
}

#[test]
fn type_catalog_should_map_bit_to_boolean() {
    let plugin = SqlServerPlugin::new();
    assert_eq!(plugin.map_type_extended(4, Some("bit")), OdbcType::Boolean);
}

#[test]
fn type_catalog_should_map_small_integer_aliases_to_smallint() {
    let plugin = SqlServerPlugin::new();
    assert_eq!(
        plugin.map_type_extended(4, Some("smallint")),
        OdbcType::SmallInt,
    );
    assert_eq!(
        plugin.map_type_extended(4, Some("tinyint")),
        OdbcType::SmallInt,
    );
}

#[test]
fn type_catalog_should_map_real_and_float_to_float_double() {
    let plugin = SqlServerPlugin::new();
    assert_eq!(plugin.map_type_extended(0, Some("real")), OdbcType::Float);
    assert_eq!(plugin.map_type_extended(0, Some("float")), OdbcType::Double);
}

#[test]
fn type_catalog_should_map_binary_family_and_json() {
    let plugin = SqlServerPlugin::new();
    for name in &["varbinary", "binary", "image"] {
        assert_eq!(plugin.map_type_extended(0, Some(name)), OdbcType::Binary);
    }
    assert_eq!(plugin.map_type_extended(0, Some("json")), OdbcType::Json);
}

#[test]
fn type_catalog_should_fall_back_when_name_unknown_or_absent() {
    let plugin = SqlServerPlugin::new();
    assert_eq!(
        plugin.map_type_extended(1, Some("custom")),
        OdbcType::Varchar
    );
    assert_eq!(plugin.map_type_extended(-5, None), OdbcType::BigInt);
}

#[test]
fn catalog_provider_should_emit_foreign_key_query_with_table_param() {
    let plugin = SqlServerPlugin::new();
    let q = plugin
        .list_foreign_keys_sql("Orders", None)
        .expect("valid catalog query");
    assert!(q.sql.contains("sys.foreign_keys"));
    assert_eq!(q.params.len(), 1);
    assert!(matches!(&q.params[0], ParamValue::String(s) if s == "Orders"));
}

#[test]
fn session_initializer_should_always_emit_arithabort_and_concat_null() {
    let plugin = SqlServerPlugin::new();
    let stmts = plugin.initialization_sql(&SessionOptions::default());
    assert!(stmts.iter().any(|s| s == "SET ARITHABORT ON"));
    assert!(stmts.iter().any(|s| s == "SET CONCAT_NULL_YIELDS_NULL ON"));
}

#[test]
fn session_initializer_should_append_extra_sql_verbatim() {
    let plugin = SqlServerPlugin::new();
    let opts = SessionOptions::new().with_extra_sql("SET LOCK_TIMEOUT 1000");
    let stmts = plugin.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s == "SET LOCK_TIMEOUT 1000"));
}

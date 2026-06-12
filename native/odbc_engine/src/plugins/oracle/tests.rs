use super::OraclePlugin;
use crate::plugins::capabilities::returning::DmlVerb;
use crate::plugins::capabilities::{SessionInitializer, SessionOptions};
use crate::plugins::driver_plugin::{DriverPlugin, OptimizationRule};
use crate::protocol::types::OdbcType;

use super::super::capabilities::{
    BulkLoader, CatalogProvider, Returnable, TypeCatalog, Upsertable,
};

#[test]
fn test_oracle_plugin_new() {
    let plugin = OraclePlugin::new();
    assert_eq!(plugin.name(), "oracle");
}

#[test]
fn test_oracle_plugin_default() {
    let plugin = OraclePlugin;
    assert_eq!(plugin.name(), "oracle");
}

#[test]
fn test_oracle_plugin_name() {
    let plugin = OraclePlugin::new();
    assert_eq!(plugin.name(), "oracle");
}

#[test]
fn test_oracle_plugin_capabilities() {
    let plugin = OraclePlugin::new();
    let caps = plugin.get_capabilities();

    assert!(caps.supports_prepared_statements);
    assert!(caps.supports_batch_operations);
    assert!(caps.supports_streaming);
    assert!(caps.supports_array_fetch);
    assert_eq!(caps.max_row_array_size, 5000);
    assert_eq!(caps.driver_name, "Oracle");
    assert_eq!(caps.driver_version, "Unknown");
}

#[test]
fn test_oracle_plugin_map_type() {
    let plugin = OraclePlugin::new();

    assert_eq!(plugin.map_type(1), OdbcType::Varchar);
    assert_eq!(plugin.map_type(2), OdbcType::Integer);
    assert_eq!(plugin.map_type(4), OdbcType::Integer); // ODBC SQL_INTEGER
    assert_eq!(plugin.map_type(-5), OdbcType::BigInt);
    assert_eq!(plugin.map_type(3), OdbcType::Decimal);
    assert_eq!(plugin.map_type(9), OdbcType::Date);
    assert_eq!(plugin.map_type(11), OdbcType::Timestamp);
    assert_eq!(plugin.map_type(-2), OdbcType::Binary);
    assert_eq!(plugin.map_type(99), OdbcType::Varchar); // Default case
}

#[test]
fn test_oracle_plugin_optimize_query_select_without_fetch() {
    let plugin = OraclePlugin::new();

    let sql = "SELECT * FROM users";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT * FROM users FETCH FIRST 1000 ROWS ONLY");
}

#[test]
fn test_oracle_plugin_optimize_query_select_with_semicolon() {
    let plugin = OraclePlugin::new();

    let sql = "SELECT * FROM users;";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT * FROM users FETCH FIRST 1000 ROWS ONLY;");
}

#[test]
fn test_oracle_plugin_optimize_query_already_has_rownum() {
    let plugin = OraclePlugin::new();

    let sql = "SELECT * FROM users WHERE ROWNUM <= 500";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT * FROM users WHERE ROWNUM <= 500");
}

#[test]
fn test_oracle_plugin_optimize_query_already_has_fetch() {
    let plugin = OraclePlugin::new();

    let sql = "SELECT * FROM users FETCH FIRST 500 ROWS ONLY";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT * FROM users FETCH FIRST 500 ROWS ONLY");
}

#[test]
fn test_oracle_plugin_optimize_query_with_where() {
    let plugin = OraclePlugin::new();

    let sql = "SELECT * FROM users WHERE id > 10";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT * FROM users WHERE id > 10");
}

#[test]
fn test_oracle_plugin_optimize_query_with_order_by() {
    let plugin = OraclePlugin::new();

    let sql = "SELECT * FROM users ORDER BY name";
    let optimized = plugin.optimize_query(sql);
    assert_eq!(optimized, "SELECT * FROM users ORDER BY name");
}

#[test]
fn test_oracle_plugin_get_optimization_rules() {
    let plugin = OraclePlugin::new();
    let rules = plugin.get_optimization_rules();

    assert_eq!(rules.len(), 4);
    assert!(matches!(rules[0], OptimizationRule::UsePreparedStatements));
    assert!(matches!(rules[1], OptimizationRule::UseBatchOperations));
    assert!(matches!(
        rules[2],
        OptimizationRule::UseArrayFetch { size: 5000 }
    ));
    assert!(matches!(rules[3], OptimizationRule::EnableStreaming));
}

#[test]
fn should_emit_user_tables_catalog_without_schema_filter() {
    let plugin = OraclePlugin::new();
    let q = plugin.list_tables_sql(None, None).unwrap();
    assert!(q.sql.contains("USER_TABLES"));
    assert!(q.params.is_empty());
}

#[test]
fn should_emit_all_tables_catalog_when_schema_provided() {
    let plugin = OraclePlugin::new();
    let q = plugin.list_tables_sql(None, Some("HR")).unwrap();
    assert!(q.sql.contains("ALL_TABLES"));
    assert!(q.sql.contains("OWNER = ?"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn should_reject_empty_table_for_list_columns_sql() {
    let plugin = OraclePlugin::new();
    assert!(plugin.list_columns_sql("   ", None).is_err());
}

#[test]
fn should_append_oracle_returning_into_bind_variables() {
    let plugin = OraclePlugin::new();
    let sql = plugin
        .append_returning_clause("INSERT INTO t (id) VALUES (?)", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(sql.contains("RETURNING"));
    assert!(sql.contains("INTO :ret_0"));
}

#[test]
fn should_map_timestamp_with_time_zone_extended_type() {
    let plugin = OraclePlugin::new();
    assert_eq!(
        plugin.map_type_extended(93, Some("TIMESTAMP WITH TIME ZONE")),
        OdbcType::TimestampWithTz
    );
}

#[test]
#[allow(
    clippy::default_constructed_unit_structs,
    reason = "intentional: exercises the impl Default for OraclePlugin"
)]
fn default_constructor_should_produce_named_plugin() {
    let plugin = OraclePlugin::default();
    assert_eq!(plugin.name(), "oracle");
}

#[test]
fn bulk_loader_should_advertise_direct_path_append_technique() {
    let plugin = OraclePlugin::new();
    assert_eq!(plugin.technique(), "direct_path_append");
    assert!(plugin.supports_native_bulk());
}

#[test]
fn upsert_should_omit_when_matched_when_only_conflict_columns() {
    let plugin = OraclePlugin::new();
    let sql = plugin
        .build_upsert_sql("HR.USERS", &["ID"], &["ID"], None)
        .expect("valid merge upsert");
    assert!(sql.starts_with("MERGE INTO"));
    assert!(!sql.contains("WHEN MATCHED THEN UPDATE"));
    assert!(sql.contains("WHEN NOT MATCHED THEN INSERT"));
}

#[test]
fn upsert_should_emit_merge_with_dual_source() {
    let plugin = OraclePlugin::new();
    let sql = plugin
        .build_upsert_sql("HR.USERS", &["ID", "NAME"], &["ID"], None)
        .expect("valid merge upsert");
    assert!(sql.contains("FROM dual"));
    assert!(sql.contains("WHEN MATCHED THEN UPDATE SET"));
}

#[test]
fn returnable_capabilities_should_advertise_no_resultset_for_oracle() {
    let plugin = OraclePlugin::new();
    assert!(plugin.supports_returning());
    assert!(!plugin.returns_resultset());
}

#[test]
fn returning_clause_should_strip_trailing_semicolon() {
    let plugin = OraclePlugin::new();
    let sql = plugin
        .append_returning_clause("INSERT INTO t (id) VALUES (?);", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(sql.contains("RETURNING"));
    assert!(sql.contains(":ret_0"));
    assert!(!sql.contains(';'));
}

#[test]
fn returning_clause_should_emit_one_bind_per_column() {
    let plugin = OraclePlugin::new();
    let sql = plugin
        .append_returning_clause(
            "INSERT INTO t (a, b) VALUES (?, ?)",
            DmlVerb::Insert,
            &["a", "b"],
        )
        .unwrap();
    assert!(sql.contains(":ret_0"));
    assert!(sql.contains(":ret_1"));
}

#[test]
fn type_catalog_should_map_interval_aliases() {
    let plugin = OraclePlugin::new();
    assert_eq!(
        plugin.map_type_extended(0, Some("interval day to second")),
        OdbcType::Interval,
    );
    assert_eq!(
        plugin.map_type_extended(0, Some("interval year to month")),
        OdbcType::Interval,
    );
}

#[test]
fn type_catalog_should_map_lob_aliases() {
    let plugin = OraclePlugin::new();
    for name in &["raw", "long raw", "blob"] {
        assert_eq!(plugin.map_type_extended(0, Some(name)), OdbcType::Binary);
    }
    assert_eq!(plugin.map_type_extended(0, Some("clob")), OdbcType::Varchar);
    assert_eq!(
        plugin.map_type_extended(0, Some("nclob")),
        OdbcType::Varchar
    );
}

#[test]
fn type_catalog_should_map_unicode_aliases() {
    let plugin = OraclePlugin::new();
    assert_eq!(
        plugin.map_type_extended(1, Some("nvarchar2")),
        OdbcType::NVarchar,
    );
    assert_eq!(
        plugin.map_type_extended(1, Some("nchar")),
        OdbcType::NVarchar
    );
}

#[test]
fn type_catalog_should_map_binary_float_double() {
    let plugin = OraclePlugin::new();
    assert_eq!(
        plugin.map_type_extended(0, Some("binary_float")),
        OdbcType::Float,
    );
    assert_eq!(
        plugin.map_type_extended(0, Some("binary_double")),
        OdbcType::Double,
    );
}

#[test]
fn type_catalog_should_fall_back_when_name_unknown_or_absent() {
    let plugin = OraclePlugin::new();
    let _ = plugin.map_type_extended(1, Some("custom_type"));
    assert_eq!(plugin.map_type_extended(4, None), OdbcType::Integer);
}

#[test]
fn list_tables_should_treat_blank_schema_as_no_filter() {
    let plugin = OraclePlugin::new();
    let q = plugin.list_tables_sql(None, Some("   ")).unwrap();
    assert!(q.sql.contains("USER_TABLES"));
    assert!(q.params.is_empty());
}

#[test]
fn list_columns_should_query_user_tab_columns_without_schema() {
    let plugin = OraclePlugin::new();
    let q = plugin.list_columns_sql("EMP", None).unwrap();
    assert!(q.sql.contains("USER_TAB_COLUMNS"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn list_columns_should_query_all_tab_columns_with_schema() {
    let plugin = OraclePlugin::new();
    let q = plugin.list_columns_sql("EMP", Some("HR")).unwrap();
    assert!(q.sql.contains("ALL_TAB_COLUMNS"));
    assert!(q.sql.contains("OWNER = ?"));
    assert_eq!(q.params.len(), 2);
}

#[test]
fn list_primary_keys_should_use_user_constraints_when_no_schema() {
    let plugin = OraclePlugin::new();
    let q = plugin.list_primary_keys_sql("EMP", None).unwrap();
    assert!(q.sql.contains("USER_CONSTRAINTS"));
    assert!(q.sql.contains("CONSTRAINT_TYPE = 'P'"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn list_primary_keys_should_use_all_constraints_with_schema() {
    let plugin = OraclePlugin::new();
    let q = plugin.list_primary_keys_sql("EMP", Some("HR")).unwrap();
    assert!(q.sql.contains("ALL_CONSTRAINTS"));
    assert_eq!(q.params.len(), 2);
}

#[test]
fn list_foreign_keys_should_pass_table_as_parameter() {
    let plugin = OraclePlugin::new();
    let q = plugin.list_foreign_keys_sql("EMP", None).unwrap();
    assert!(q.sql.contains("CONSTRAINT_TYPE = 'R'"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn list_indexes_should_query_user_ind_columns_without_schema() {
    let plugin = OraclePlugin::new();
    let q = plugin.list_indexes_sql("EMP", None).unwrap();
    assert!(q.sql.contains("USER_IND_COLUMNS"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn list_indexes_should_query_all_ind_columns_with_schema() {
    let plugin = OraclePlugin::new();
    let q = plugin.list_indexes_sql("EMP", Some("HR")).unwrap();
    assert!(q.sql.contains("ALL_IND_COLUMNS"));
    assert_eq!(q.params.len(), 2);
}

#[test]
fn session_initializer_should_always_emit_nls_defaults() {
    let plugin = OraclePlugin::new();
    let stmts = plugin.initialization_sql(&SessionOptions::default());
    assert!(stmts.iter().any(|s| s.contains("NLS_DATE_FORMAT")));
    assert!(stmts.iter().any(|s| s.contains("NLS_TIMESTAMP_FORMAT")));
    assert!(stmts.iter().any(|s| s.contains("NLS_NUMERIC_CHARACTERS")));
}

#[test]
fn session_initializer_should_emit_time_zone_with_escaped_quotes() {
    let plugin = OraclePlugin::new();
    let opts = SessionOptions::new().with_timezone("UTC");
    let stmts = plugin.initialization_sql(&opts);
    assert!(stmts
        .iter()
        .any(|s| s == "ALTER SESSION SET TIME_ZONE='UTC'"));
}

#[test]
fn session_initializer_should_emit_current_schema_when_schema_set() {
    let plugin = OraclePlugin::new();
    let opts = SessionOptions::new().with_schema("HR");
    let stmts = plugin.initialization_sql(&opts);
    assert!(stmts
        .iter()
        .any(|s| s.contains("ALTER SESSION SET CURRENT_SCHEMA")));
}

#[test]
fn session_initializer_should_pass_through_extra_sql_verbatim() {
    let plugin = OraclePlugin::new();
    let opts = SessionOptions::new().with_extra_sql("ALTER SESSION SET STATISTICS_LEVEL=ALL");
    let stmts = plugin.initialization_sql(&opts);
    assert!(stmts
        .iter()
        .any(|s| s == "ALTER SESSION SET STATISTICS_LEVEL=ALL"));
}

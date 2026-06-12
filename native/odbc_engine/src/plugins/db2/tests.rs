use super::Db2Plugin;
use crate::error::OdbcError;
use crate::plugins::capabilities::returning::DmlVerb;
use crate::plugins::capabilities::{
    CatalogProvider, Returnable, SessionInitializer, SessionOptions, TypeCatalog, Upsertable,
};
use crate::plugins::driver_plugin::{DriverPlugin, OptimizationRule};
use crate::protocol::types::OdbcType;
use crate::protocol::ParamValue;

#[test]
fn name_is_db2() {
    assert_eq!(Db2Plugin::new().name(), "db2");
}

#[test]
fn optimize_query_adds_fetch_first() {
    let p = Db2Plugin::new();
    assert_eq!(
        p.optimize_query("SELECT * FROM t"),
        "SELECT * FROM t FETCH FIRST 1000 ROWS ONLY"
    );
}

#[test]
fn optimize_query_skips_when_already_present() {
    let p = Db2Plugin::new();
    let s = "SELECT * FROM t FETCH FIRST 50 ROWS ONLY";
    assert_eq!(p.optimize_query(s), s);
}

#[test]
fn upsert_uses_merge_with_values_alias() {
    let p = Db2Plugin::new();
    let sql = p
        .build_upsert_sql("u", &["id", "name"], &["id"], None)
        .unwrap();
    assert!(sql.starts_with("MERGE INTO \"u\" t"));
    assert!(sql.contains("USING (VALUES (?, ?))"));
    assert!(sql.contains("WHEN MATCHED THEN UPDATE SET"));
    assert!(sql.contains("WHEN NOT MATCHED THEN INSERT"));
}

#[test]
fn returning_uses_final_table() {
    let p = Db2Plugin::new();
    let r = p
        .append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["id"])
        .unwrap();
    assert_eq!(
        r,
        "SELECT \"id\" FROM FINAL TABLE (INSERT INTO t (a) VALUES (?))"
    );
}

#[test]
fn returning_for_delete_is_unsupported() {
    let p = Db2Plugin::new();
    let r = p.append_returning_clause("DELETE FROM t WHERE id=?", DmlVerb::Delete, &["id"]);
    assert!(matches!(r, Err(OdbcError::UnsupportedFeature(_))));
}

#[test]
fn type_catalog_recognises_db2_specific_types() {
    let p = Db2Plugin::new();
    assert_eq!(p.map_type_extended(1, Some("GRAPHIC")), OdbcType::NVarchar);
    assert_eq!(p.map_type_extended(1, Some("XML")), OdbcType::Json);
    assert_eq!(p.map_type_extended(1, Some("BLOB")), OdbcType::Binary);
}

#[test]
fn session_init_emits_set_current_schema() {
    let p = Db2Plugin::new();
    let opts = SessionOptions::new().with_schema("MYAPP");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s.contains("SET CURRENT SCHEMA")));
}

#[test]
fn should_emit_list_tables_with_schema_param() {
    let p = Db2Plugin::new();
    let q = p.list_tables_sql(None, Some("myapp")).unwrap();
    assert!(q.sql.contains("TABSCHEMA = UPPER(?)"));
    assert_eq!(q.params.len(), 1);
    assert_eq!(q.params[0], ParamValue::String("myapp".to_string()));
}

#[test]
fn should_emit_list_columns_without_schema() {
    let p = Db2Plugin::new();
    let q = p.list_columns_sql("ORDERS", None).unwrap();
    assert!(q.sql.contains("TABNAME = UPPER(?)"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn should_escape_application_name_quotes_in_session_init() {
    let p = Db2Plugin::new();
    let opts = SessionOptions::new().with_application_name("app'name");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s.contains("app''name")));
}

#[test]
fn should_optimize_query_before_semicolon() {
    let p = Db2Plugin::new();
    let sql = "SELECT id FROM t;";
    let out = p.optimize_query(sql);
    assert!(out.contains("FETCH FIRST 1000 ROWS ONLY"));
    assert!(out.ends_with(';'));
}

#[test]
#[allow(
    clippy::default_constructed_unit_structs,
    reason = "intentional: exercises the impl Default for Db2Plugin"
)]
fn default_constructor_should_produce_named_plugin() {
    let p = Db2Plugin::default();
    assert_eq!(p.name(), "db2");
}

#[test]
fn capabilities_should_advertise_db2_settings() {
    let p = Db2Plugin::new();
    let caps = p.get_capabilities();
    assert!(caps.supports_prepared_statements);
    assert!(caps.supports_batch_operations);
    assert!(caps.supports_streaming);
    assert!(caps.supports_array_fetch);
    assert_eq!(caps.max_row_array_size, 2000);
    assert_eq!(caps.driver_name, "IBM Db2");
}

#[test]
fn optimize_query_should_skip_when_clauses_present() {
    let p = Db2Plugin::new();
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
fn optimization_rules_should_match_db2_settings() {
    let p = Db2Plugin::new();
    let rules = p.get_optimization_rules();
    assert!(rules
        .iter()
        .any(|r| matches!(r, OptimizationRule::UseArrayFetch { size: 2000 })));
}

#[test]
fn upsert_should_omit_when_matched_when_only_conflict_columns() {
    let p = Db2Plugin::new();
    let sql = p
        .build_upsert_sql("u", &["id"], &["id"], None)
        .expect("valid merge upsert");
    assert!(!sql.contains("WHEN MATCHED THEN UPDATE"));
    assert!(sql.contains("WHEN NOT MATCHED THEN INSERT"));
}

#[test]
fn returnable_should_be_supported() {
    let p = Db2Plugin::new();
    assert!(p.supports_returning());
}

#[test]
fn returning_for_update_should_use_final_table() {
    let p = Db2Plugin::new();
    let r = p
        .append_returning_clause("UPDATE t SET v = ? WHERE id = ?", DmlVerb::Update, &["v"])
        .unwrap();
    assert!(r.contains("SELECT \"v\" FROM FINAL TABLE ("));
    assert!(r.contains("UPDATE t SET v = ?"));
}

#[test]
fn returning_should_strip_trailing_semicolon() {
    let p = Db2Plugin::new();
    let r = p
        .append_returning_clause("INSERT INTO t (a) VALUES (?);", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(!r.contains(';'));
}

#[test]
fn type_catalog_should_map_db2_string_aliases() {
    let p = Db2Plugin::new();
    for name in &["graphic", "vargraphic", "long vargraphic"] {
        assert_eq!(p.map_type_extended(1, Some(name)), OdbcType::NVarchar);
    }
    assert_eq!(p.map_type_extended(1, Some("clob")), OdbcType::Varchar);
    assert_eq!(p.map_type_extended(1, Some("dbclob")), OdbcType::Varchar);
}

#[test]
fn type_catalog_should_map_db2_numeric_aliases() {
    let p = Db2Plugin::new();
    assert_eq!(p.map_type_extended(0, Some("real")), OdbcType::Float);
    assert_eq!(p.map_type_extended(0, Some("double")), OdbcType::Double);
    assert_eq!(
        p.map_type_extended(0, Some("double precision")),
        OdbcType::Double,
    );
    assert_eq!(p.map_type_extended(0, Some("smallint")), OdbcType::SmallInt,);
}

#[test]
fn type_catalog_should_fall_back_when_type_name_unknown_or_absent() {
    let p = Db2Plugin::new();
    let _ = p.map_type_extended(1, Some("totally_unknown"));
    let _ = p.map_type_extended(4, None);
}

#[test]
fn list_tables_should_filter_system_schemas_when_no_schema_given() {
    let p = Db2Plugin::new();
    let q = p.list_tables_sql(None, None).unwrap();
    assert!(q.sql.contains("TABSCHEMA NOT LIKE 'SYS%'"));
    assert!(q.params.is_empty());
}

#[test]
fn list_tables_should_treat_blank_schema_as_no_filter() {
    let p = Db2Plugin::new();
    let q = p.list_tables_sql(None, Some("   ")).unwrap();
    assert!(q.params.is_empty());
}

#[test]
fn list_columns_should_filter_by_schema_when_provided() {
    let p = Db2Plugin::new();
    let q = p.list_columns_sql("orders", Some("app")).unwrap();
    assert!(q.sql.contains("TABSCHEMA = UPPER(?)"));
    assert_eq!(q.params.len(), 2);
}

#[test]
fn primary_keys_should_pass_table_as_parameter() {
    let p = Db2Plugin::new();
    let q = p.list_primary_keys_sql("ORDERS", None).unwrap();
    assert!(q.sql.contains("SYSCAT.KEYCOLUSE"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn foreign_keys_should_pass_table_as_parameter() {
    let p = Db2Plugin::new();
    let q = p.list_foreign_keys_sql("ORDERS", None).unwrap();
    assert!(q.sql.contains("SYSCAT.REFERENCES"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn indexes_should_pass_table_as_parameter() {
    let p = Db2Plugin::new();
    let q = p.list_indexes_sql("ORDERS", None).unwrap();
    assert!(q.sql.contains("SYSCAT.INDEXES"));
    assert_eq!(q.params.len(), 1);
}

#[test]
fn session_init_should_pass_through_extra_sql_verbatim() {
    let p = Db2Plugin::new();
    let opts = SessionOptions::new().with_extra_sql("SET CURRENT DEGREE = '4'");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s == "SET CURRENT DEGREE = '4'"));
}

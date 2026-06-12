use super::SqlitePlugin;
use crate::plugins::capabilities::returning::DmlVerb;
use crate::plugins::capabilities::{
    CatalogProvider, Returnable, SessionInitializer, SessionOptions, TypeCatalog, Upsertable,
};
use crate::plugins::driver_plugin::DriverPlugin;
use crate::protocol::types::OdbcType;
use crate::protocol::ParamValue;

#[test]
fn name_is_sqlite() {
    assert_eq!(SqlitePlugin::new().name(), "sqlite");
}

#[test]
fn optimize_query_is_identity() {
    let p = SqlitePlugin::new();
    assert_eq!(p.optimize_query("SELECT * FROM t"), "SELECT * FROM t");
}

#[test]
fn upsert_uses_excluded_qualifier() {
    let p = SqlitePlugin::new();
    let sql = p
        .build_upsert_sql("users", &["id", "name"], &["id"], None)
        .unwrap();
    assert!(sql.contains("ON CONFLICT (\"id\")"));
    assert!(sql.contains("DO UPDATE SET \"name\" = excluded.\"name\""));
}

#[test]
fn upsert_with_no_update_columns_does_nothing() {
    let p = SqlitePlugin::new();
    let sql = p.build_upsert_sql("t", &["id"], &["id"], None).unwrap();
    assert!(sql.contains("DO NOTHING"));
}

#[test]
fn returning_appended_after_dml() {
    let p = SqlitePlugin::new();
    let r = p
        .append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(r.ends_with("RETURNING \"id\""));
}

#[test]
fn type_catalog_recognises_sqlite_storage_classes() {
    let p = SqlitePlugin::new();
    assert_eq!(p.map_type_extended(1, Some("INTEGER")), OdbcType::Integer);
    assert_eq!(p.map_type_extended(1, Some("VARCHAR")), OdbcType::Varchar);
    assert_eq!(p.map_type_extended(1, Some("BLOB")), OdbcType::Binary);
    assert_eq!(p.map_type_extended(1, Some("REAL")), OdbcType::Double);
    assert_eq!(p.map_type_extended(1, Some("BOOLEAN")), OdbcType::Boolean);
}

#[test]
fn session_init_sets_pragmas() {
    let p = SqlitePlugin::new();
    let stmts = p.initialization_sql(&SessionOptions::default());
    assert!(stmts.iter().any(|s| s.contains("foreign_keys")));
    assert!(stmts.iter().any(|s| s.contains("journal_mode")));
}

#[test]
fn should_emit_list_foreign_keys_with_two_table_params() {
    let p = SqlitePlugin::new();
    let q = p.list_foreign_keys_sql("  items  ", None).unwrap();
    assert!(q.sql.contains("pragma_foreign_key_list"));
    assert_eq!(q.params.len(), 2);
    assert_eq!(q.params[0], ParamValue::String("items".to_string()));
    assert_eq!(q.params[1], ParamValue::String("items".to_string()));
}

#[test]
fn should_emit_list_indexes_sql() {
    let p = SqlitePlugin::new();
    let q = p.list_indexes_sql("users", None).unwrap();
    assert!(q.sql.contains("pragma_index_list"));
    assert_eq!(q.params.len(), 2);
}

#[test]
fn should_map_blob_storage_class_to_binary() {
    let p = SqlitePlugin::new();
    assert_eq!(p.map_type_extended(-3, Some("BLOB")), OdbcType::Binary);
}

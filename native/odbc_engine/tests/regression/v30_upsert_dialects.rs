//! v3.0 — `Upsertable` produces dialect-correct SQL for every plugin.

use odbc_engine::plugins::capabilities::Upsertable;
use odbc_engine::plugins::{
    db2::Db2Plugin, mariadb::MariaDbPlugin, mysql::MySqlPlugin, oracle::OraclePlugin,
    postgres::PostgresPlugin, snowflake::SnowflakePlugin, sqlite::SqlitePlugin,
    sqlserver::SqlServerPlugin, sybase::SybasePlugin,
};

#[test]
fn postgres_upsert_uses_on_conflict() {
    let p = PostgresPlugin::new();
    let sql = p
        .build_upsert_sql("u", &["id", "name"], &["id"], None)
        .unwrap();
    assert!(sql.contains("ON CONFLICT (\"id\") DO UPDATE SET"));
    assert!(sql.contains("\"name\" = EXCLUDED.\"name\""));
}

#[test]
fn mysql_upsert_uses_on_duplicate_key_with_backticks() {
    let p = MySqlPlugin::new();
    let sql = p
        .build_upsert_sql("u", &["id", "name"], &["id"], None)
        .unwrap();
    assert!(sql.contains("ON DUPLICATE KEY UPDATE"));
    assert!(sql.contains("`name` = VALUES(`name`)"));
}

#[test]
fn mariadb_upsert_matches_mysql_idiom() {
    let p = MariaDbPlugin::new();
    let sql = p
        .build_upsert_sql("u", &["id", "name"], &["id"], None)
        .unwrap();
    assert!(sql.contains("ON DUPLICATE KEY UPDATE"));
}

#[test]
fn sqlserver_upsert_uses_merge_with_brackets() {
    let p = SqlServerPlugin::new();
    let sql = p
        .build_upsert_sql("dbo.u", &["id", "name"], &["id"], None)
        .unwrap();
    assert!(sql.starts_with("MERGE INTO [dbo].[u] AS t"));
    assert!(sql.contains("USING (SELECT ? AS [id], ? AS [name])"));
    assert!(sql.contains("WHEN MATCHED THEN UPDATE SET"));
    assert!(sql.contains("WHEN NOT MATCHED THEN INSERT"));
    assert!(sql.ends_with(';'));
}

#[test]
fn oracle_upsert_uses_merge_with_dual() {
    let p = OraclePlugin::new();
    let sql = p
        .build_upsert_sql("u", &["id", "name"], &["id"], None)
        .unwrap();
    assert!(sql.contains("USING (SELECT ? \"id\", ? \"name\" FROM dual)"));
    assert!(sql.contains("MERGE INTO \"u\" t"));
}

#[test]
fn sqlite_upsert_uses_excluded_qualifier() {
    let p = SqlitePlugin::new();
    let sql = p
        .build_upsert_sql("u", &["id", "name"], &["id"], None)
        .unwrap();
    assert!(sql.contains("ON CONFLICT (\"id\") DO UPDATE SET"));
    assert!(sql.contains("\"name\" = excluded.\"name\""));
}

#[test]
fn db2_upsert_uses_merge_with_values() {
    let p = Db2Plugin::new();
    let sql = p
        .build_upsert_sql("u", &["id", "name"], &["id"], None)
        .unwrap();
    assert!(sql.contains("MERGE INTO \"u\" t"));
    assert!(sql.contains("USING (VALUES (?, ?))"));
    assert!(sql.contains("WHEN MATCHED THEN UPDATE SET"));
}

#[test]
fn snowflake_upsert_uses_merge_select() {
    let p = SnowflakePlugin::new();
    let sql = p
        .build_upsert_sql("u", &["id", "name"], &["id"], None)
        .unwrap();
    assert!(sql.contains("MERGE INTO \"u\" t"));
    assert!(sql.contains("USING (SELECT ? AS \"id\", ? AS \"name\")"));
}

#[test]
fn sybase_upsert_explicitly_unsupported() {
    let p = SybasePlugin::new();
    let r = p.build_upsert_sql("u", &["id"], &["id"], None);
    assert!(r.is_err());
}

#[test]
fn upsert_validates_inputs() {
    let p = PostgresPlugin::new();
    assert!(p.build_upsert_sql("", &["a"], &["a"], None).is_err());
    assert!(p.build_upsert_sql("t", &[], &["a"], None).is_err());
    assert!(p.build_upsert_sql("t", &["a"], &[], None).is_err());
    // Conflict column not in columns
    assert!(p.build_upsert_sql("t", &["a", "b"], &["c"], None).is_err());
    // SQL injection
    assert!(p
        .build_upsert_sql("t; DROP TABLE x", &["a"], &["a"], None)
        .is_err());
}

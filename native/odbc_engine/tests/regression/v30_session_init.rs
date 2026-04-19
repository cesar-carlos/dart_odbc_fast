//! v3.0 — `SessionInitializer` produces dialect-correct setup statements.

use odbc_engine::plugins::capabilities::SessionInitializer;
use odbc_engine::plugins::capabilities::SessionOptions;
use odbc_engine::plugins::{
    db2::Db2Plugin, mariadb::MariaDbPlugin, mysql::MySqlPlugin, oracle::OraclePlugin,
    postgres::PostgresPlugin, snowflake::SnowflakePlugin, sqlite::SqlitePlugin,
    sqlserver::SqlServerPlugin, sybase::SybasePlugin,
};

#[test]
fn postgres_emits_application_name_and_search_path() {
    let p = PostgresPlugin::new();
    let opts = SessionOptions::new()
        .with_application_name("svc")
        .with_timezone("UTC")
        .with_schema("public");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s == "SET application_name = 'svc'"));
    assert!(stmts.iter().any(|s| s == "SET TIME ZONE 'UTC'"));
    assert!(stmts.iter().any(|s| s.starts_with("SET search_path TO")));
}

#[test]
fn mysql_emits_set_names_default_utf8mb4() {
    let p = MySqlPlugin::new();
    let stmts = p.initialization_sql(&SessionOptions::default());
    assert!(stmts.iter().any(|s| s == "SET NAMES utf8mb4"));
}

#[test]
fn mariadb_emits_set_names_with_custom_charset() {
    let p = MariaDbPlugin::new();
    let opts = SessionOptions::new().with_charset("utf8");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s == "SET NAMES utf8"));
}

#[test]
fn oracle_emits_alter_session_nls() {
    let p = OraclePlugin::new();
    let stmts = p.initialization_sql(&SessionOptions::default());
    assert!(stmts.iter().any(|s| s.contains("NLS_DATE_FORMAT")));
    assert!(stmts.iter().any(|s| s.contains("NLS_TIMESTAMP_FORMAT")));
    assert!(stmts.iter().any(|s| s.contains("NLS_NUMERIC_CHARACTERS")));
}

#[test]
fn sqlserver_emits_arithabort_and_concat_null() {
    let p = SqlServerPlugin::new();
    let stmts = p.initialization_sql(&SessionOptions::default());
    assert!(stmts.iter().any(|s| s == "SET ARITHABORT ON"));
    assert!(stmts.iter().any(|s| s == "SET CONCAT_NULL_YIELDS_NULL ON"));
}

#[test]
fn sqlite_emits_pragmas() {
    let p = SqlitePlugin::new();
    let stmts = p.initialization_sql(&SessionOptions::default());
    assert!(stmts.iter().any(|s| s == "PRAGMA foreign_keys = ON"));
    assert!(stmts.iter().any(|s| s == "PRAGMA journal_mode = WAL"));
    assert!(stmts.iter().any(|s| s == "PRAGMA synchronous = NORMAL"));
}

#[test]
fn db2_emits_set_current_schema_when_provided() {
    let p = Db2Plugin::new();
    let opts = SessionOptions::new().with_schema("MYAPP");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s.contains("SET CURRENT SCHEMA")));
}

#[test]
fn snowflake_emits_query_tag_and_use_schema() {
    let p = SnowflakePlugin::new();
    let opts = SessionOptions::new()
        .with_application_name("dart-app")
        .with_schema("PUBLIC")
        .with_timezone("UTC");
    let stmts = p.initialization_sql(&opts);
    assert!(stmts.iter().any(|s| s.contains("QUERY_TAG = 'dart-app'")));
    assert!(stmts.iter().any(|s| s.contains("TIMEZONE = 'UTC'")));
    assert!(stmts.iter().any(|s| s.starts_with("USE SCHEMA")));
}

#[test]
fn sybase_emits_quoted_identifier_and_chained_off() {
    let p = SybasePlugin::new();
    let stmts = p.initialization_sql(&SessionOptions::default());
    assert!(stmts.iter().any(|s| s == "SET QUOTED_IDENTIFIER ON"));
    assert!(stmts.iter().any(|s| s == "SET CHAINED OFF"));
}

#[test]
fn extra_sql_is_appended_for_every_plugin() {
    let opts = SessionOptions::new().with_extra_sql("-- custom");
    let plugins: Vec<Vec<String>> = vec![
        PostgresPlugin::new().initialization_sql(&opts),
        MySqlPlugin::new().initialization_sql(&opts),
        MariaDbPlugin::new().initialization_sql(&opts),
        OraclePlugin::new().initialization_sql(&opts),
        SqlServerPlugin::new().initialization_sql(&opts),
        SqlitePlugin::new().initialization_sql(&opts),
        Db2Plugin::new().initialization_sql(&opts),
        SnowflakePlugin::new().initialization_sql(&opts),
        SybasePlugin::new().initialization_sql(&opts),
    ];
    for stmts in plugins {
        assert!(stmts.iter().any(|s| s == "-- custom"));
    }
}

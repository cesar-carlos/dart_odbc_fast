//! v3.0 — `Returnable` produces dialect-correct RETURNING/OUTPUT clauses.

use odbc_engine::plugins::capabilities::returning::DmlVerb;
use odbc_engine::plugins::capabilities::Returnable;
use odbc_engine::plugins::{
    db2::Db2Plugin, mariadb::MariaDbPlugin, mysql::MySqlPlugin, oracle::OraclePlugin,
    postgres::PostgresPlugin, snowflake::SnowflakePlugin, sqlite::SqlitePlugin,
    sqlserver::SqlServerPlugin, sybase::SybasePlugin,
};
use odbc_engine::OdbcError;

#[test]
fn postgres_appends_returning_clause() {
    let p = PostgresPlugin::new();
    let r = p
        .append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(r.ends_with("RETURNING \"id\""));
}

#[test]
fn sqlserver_outputs_inserted_for_insert() {
    let p = SqlServerPlugin::new();
    let r = p
        .append_returning_clause("INSERT INTO [t] ([a]) VALUES (?)", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(r.contains("OUTPUT INSERTED.[id]"));
    assert!(r.contains("VALUES (?)"));
}

#[test]
fn sqlserver_outputs_deleted_for_delete() {
    let p = SqlServerPlugin::new();
    let r = p
        .append_returning_clause("DELETE FROM [t] WHERE id = ?", DmlVerb::Delete, &["id"])
        .unwrap();
    assert!(r.contains("OUTPUT DELETED.[id]"));
    assert!(r.contains("WHERE"));
}

#[test]
fn oracle_appends_returning_into_outbinds() {
    let p = OraclePlugin::new();
    assert!(!p.returns_resultset());
    let r = p
        .append_returning_clause(
            "INSERT INTO t (a) VALUES (?)",
            DmlVerb::Insert,
            &["id", "created_at"],
        )
        .unwrap();
    assert!(r.contains("RETURNING \"id\", \"created_at\""));
    assert!(r.contains("INTO :ret_0, :ret_1"));
}

#[test]
fn mariadb_appends_returning_clause() {
    let p = MariaDbPlugin::new();
    let r = p
        .append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(r.ends_with("RETURNING \"id\""));
}

#[test]
fn mysql_returning_unsupported() {
    let p = MySqlPlugin::new();
    assert!(!p.supports_returning());
    let r = p.append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["id"]);
    assert!(matches!(r, Err(OdbcError::UnsupportedFeature(_))));
}

#[test]
fn sqlite_appends_returning_clause() {
    let p = SqlitePlugin::new();
    let r = p
        .append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(r.ends_with("RETURNING \"id\""));
}

#[test]
fn db2_uses_from_final_table() {
    let p = Db2Plugin::new();
    let r = p
        .append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(r.starts_with("SELECT \"id\" FROM FINAL TABLE"));
}

#[test]
fn db2_returning_for_delete_unsupported() {
    let p = Db2Plugin::new();
    let r = p.append_returning_clause("DELETE FROM t WHERE id=?", DmlVerb::Delete, &["id"]);
    assert!(matches!(r, Err(OdbcError::UnsupportedFeature(_))));
}

#[test]
fn snowflake_appends_returning_clause() {
    let p = SnowflakePlugin::new();
    let r = p
        .append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["id"])
        .unwrap();
    assert!(r.ends_with("RETURNING \"id\""));
}

#[test]
fn sybase_returning_explicitly_unsupported() {
    let p = SybasePlugin::new();
    assert!(!p.supports_returning());
    let r = p.append_returning_clause("INSERT INTO t (a) VALUES (?)", DmlVerb::Insert, &["id"]);
    assert!(matches!(r, Err(OdbcError::UnsupportedFeature(_))));
}

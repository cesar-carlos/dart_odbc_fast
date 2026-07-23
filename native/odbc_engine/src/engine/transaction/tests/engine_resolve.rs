//! Regression: savepoint dialect pins must not force `ENGINE_UNKNOWN` /
//! hardcoded SQL Server for isolation / lock-timeout matrix selection.

use super::{quoting_for, resolve_engine_and_dialect_from_id, SavepointDialect};
use crate::engine::core::{
    ENGINE_DB2, ENGINE_ORACLE, ENGINE_POSTGRES, ENGINE_SQLITE, ENGINE_SQLSERVER, ENGINE_UNKNOWN,
};
use crate::engine::transaction::dialect_sql::{
    build_isolation_sql, build_lock_timeout_sql, IsolationSql,
};
use crate::engine::transaction::{IsolationLevel, LockTimeout};
use std::borrow::Cow;
use std::sync::OnceLock;

#[test]
fn sql92_dialect_keeps_live_postgres_engine_for_isolation() {
    let (engine, dialect) =
        resolve_engine_and_dialect_from_id(ENGINE_POSTGRES, SavepointDialect::Sql92);
    assert_eq!(engine, ENGINE_POSTGRES);
    assert_eq!(dialect, SavepointDialect::Sql92);
    assert_ne!(engine, ENGINE_UNKNOWN);

    let sql = build_isolation_sql(engine, IsolationLevel::RepeatableRead).expect("sql");
    assert_eq!(
        sql,
        IsolationSql::Execute(Cow::Owned(
            "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ".to_string()
        ))
    );
}

#[test]
fn sql92_dialect_keeps_live_sqlite_engine_for_pragma_isolation() {
    let (engine, dialect) =
        resolve_engine_and_dialect_from_id(ENGINE_SQLITE, SavepointDialect::Sql92);
    assert_eq!(engine, ENGINE_SQLITE);
    assert_eq!(dialect, SavepointDialect::Sql92);

    let sql = build_isolation_sql(engine, IsolationLevel::ReadUncommitted).expect("sql");
    assert_eq!(
        sql,
        IsolationSql::Execute(Cow::Borrowed("PRAGMA read_uncommitted = 1"))
    );
}

#[test]
fn sql92_dialect_keeps_live_oracle_engine_for_restricted_isolation() {
    let (engine, _) = resolve_engine_and_dialect_from_id(ENGINE_ORACLE, SavepointDialect::Sql92);
    assert_eq!(engine, ENGINE_ORACLE);
    let err = build_isolation_sql(engine, IsolationLevel::ReadUncommitted)
        .expect_err("oracle rejects RU");
    assert!(err.to_string().contains("Oracle does not support"));
}

#[test]
fn sql92_dialect_keeps_live_db2_engine_for_set_current() {
    let (engine, _) = resolve_engine_and_dialect_from_id(ENGINE_DB2, SavepointDialect::Sql92);
    let sql = build_isolation_sql(engine, IsolationLevel::ReadCommitted).expect("sql");
    assert_eq!(
        sql,
        IsolationSql::Execute(Cow::Owned("SET CURRENT ISOLATION = CS".to_string()))
    );
}

#[test]
fn sqlserver_dialect_still_resolves_live_engine_not_forced_only_for_savepoints() {
    // Caller pins SqlServer savepoint syntax on a postgres connection:
    // savepoint dialect stays SqlServer, but isolation matrix must use postgres.
    let (engine, dialect) =
        resolve_engine_and_dialect_from_id(ENGINE_POSTGRES, SavepointDialect::SqlServer);
    assert_eq!(engine, ENGINE_POSTGRES);
    assert_eq!(dialect, SavepointDialect::SqlServer);

    let sql = build_lock_timeout_sql(engine, LockTimeout::from_millis(100))
        .expect("ok")
        .expect("postgres set local");
    assert_eq!(sql, "SET LOCAL lock_timeout = '100ms'");
}

#[test]
fn auto_dialect_resolves_sqlserver_engine_to_sqlserver_savepoint() {
    let (engine, dialect) =
        resolve_engine_and_dialect_from_id(ENGINE_SQLSERVER, SavepointDialect::Auto);
    assert_eq!(engine, ENGINE_SQLSERVER);
    assert_eq!(dialect, SavepointDialect::SqlServer);
}

#[test]
fn auto_dialect_resolves_non_sqlserver_to_sql92_savepoint() {
    let (_, dialect) = resolve_engine_and_dialect_from_id(ENGINE_POSTGRES, SavepointDialect::Auto);
    assert_eq!(dialect, SavepointDialect::Sql92);
}

#[test]
fn sql92_savepoint_quoting_unchanged_when_engine_is_postgres() {
    let (_, dialect) = resolve_engine_and_dialect_from_id(ENGINE_POSTGRES, SavepointDialect::Sql92);
    assert_eq!(
        quoting_for(dialect),
        crate::engine::identifier::IdentifierQuoting::DoubleQuote
    );
}

#[test]
fn engine_id_cache_once_lock_keeps_first_value() {
    // Mirrors CachedConnection::engine_id OnceLock semantics without a live
    // ODBC handle: first set wins; subsequent reads return the cached value.
    let cache: OnceLock<&'static str> = OnceLock::new();
    assert!(cache.get().is_none());
    let _ = cache.set(ENGINE_POSTGRES);
    assert_eq!(cache.get().copied(), Some(ENGINE_POSTGRES));
    let _ = cache.set(ENGINE_SQLSERVER);
    assert_eq!(
        cache.get().copied(),
        Some(ENGINE_POSTGRES),
        "OnceLock must keep the first engine_id"
    );
}

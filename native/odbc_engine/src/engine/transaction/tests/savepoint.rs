use super::{
    quote_identifier, quoting_for, validate_identifier, HandleManager, IsolationLevel, OdbcError,
    SavepointDialect, SharedHandleManager, Transaction, TransactionState,
};
use std::sync::{Arc, Mutex};

#[test]
fn savepoint_dialect_from_u32_default_is_auto() {
    assert_eq!(SavepointDialect::from_u32(0), SavepointDialect::Auto);
    assert_eq!(SavepointDialect::from_u32(99), SavepointDialect::Auto);
}
#[test]
fn savepoint_dialect_from_u32_explicit_codes() {
    assert_eq!(SavepointDialect::from_u32(1), SavepointDialect::SqlServer);
    assert_eq!(SavepointDialect::from_u32(2), SavepointDialect::Sql92);
}
#[test]
fn savepoint_dialect_sql_keywords_sql92() {
    let create_sql = format!("SAVEPOINT {}", "sp1");
    let rollback_sql = format!("ROLLBACK TO SAVEPOINT {}", "sp1");
    let release_sql = format!("RELEASE SAVEPOINT {}", "sp1");
    assert_eq!(create_sql, "SAVEPOINT sp1");
    assert_eq!(rollback_sql, "ROLLBACK TO SAVEPOINT sp1");
    assert_eq!(release_sql, "RELEASE SAVEPOINT sp1");
}
#[test]
fn savepoint_dialect_sql_keywords_sqlserver() {
    let create_sql = format!("SAVE TRANSACTION {}", "sp1");
    let rollback_sql = format!("ROLLBACK TRANSACTION {}", "sp1");
    assert_eq!(create_sql, "SAVE TRANSACTION sp1");
    assert_eq!(rollback_sql, "ROLLBACK TRANSACTION sp1");
}
#[test]
fn savepoint_create_rejects_injection_via_transaction_method() {
    // Transaction with no real connection — savepoint_create must reject
    // BEFORE attempting any SQL execution, so the missing connection is
    // never reached.
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        999, // bogus conn_id; identifier validation must short-circuit
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
    );
    for bad in [
        "sp; DROP TABLE users--",
        "sp\";DROP TABLE x;--",
        "sp' OR '1'='1",
        "",
        "1bad_leading_digit",
        "sp space",
    ] {
        let r = txn.savepoint_create(bad);
        assert!(
            matches!(r, Err(OdbcError::ValidationError(_))),
            "savepoint_create must reject {bad:?}, got {r:?}"
        );
    }
}
#[test]
fn savepoint_rollback_to_rejects_injection() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        999,
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
    );
    let r = txn.savepoint_rollback_to("sp; DROP TABLE x--");
    assert!(matches!(r, Err(OdbcError::ValidationError(_))));
}
#[test]
fn savepoint_release_is_noop_on_sqlserver_dialect() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test_with_dialect(
        handles,
        999,
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
        SavepointDialect::SqlServer,
    );
    // SQL Server has no RELEASE SAVEPOINT — implementation returns Ok(())
    // without touching the connection (so the bogus conn_id is fine).
    assert!(txn.savepoint_release("sp1").is_ok());
}
#[test]
fn savepoint_release_still_validates_identifier_on_sqlserver() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test_with_dialect(
        handles,
        999,
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
        SavepointDialect::SqlServer,
    );
    // Even though SQL Server has no RELEASE, we still validate the name to
    // give the same defensive guarantee on every dialect.
    assert!(matches!(
        txn.savepoint_release("sp; DROP TABLE x--"),
        Err(OdbcError::ValidationError(_))
    ));
}
#[test]
fn resolve_savepoint_dialect_maps_sqlserver_and_others() {
    use crate::engine::core::ENGINE_SQLSERVER;

    assert_eq!(
        super::super::resolve_savepoint_dialect_for_engine(ENGINE_SQLSERVER),
        SavepointDialect::SqlServer
    );
    assert_eq!(
        super::super::resolve_savepoint_dialect_for_engine("postgres"),
        SavepointDialect::Sql92
    );
}
#[test]
fn savepoint_create_without_connection_fails_after_identifier_validation() {
    let txn = Transaction::for_test_no_conn(
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
        SavepointDialect::Sql92,
    );
    let result = txn.savepoint_create("sp1");
    assert!(
        result.is_err(),
        "bogus conn_id must fail once SQL is dispatched"
    );
}
#[test]
fn savepoint_sqlserver_uses_bracket_quoting_in_create_sql() {
    validate_identifier("sp1").unwrap();
    let qname = quote_identifier("sp1", quoting_for(SavepointDialect::SqlServer)).unwrap();
    let sql = format!("SAVE TRANSACTION {qname}");
    assert_eq!(sql, "SAVE TRANSACTION [sp1]");
}
#[test]
fn transaction_savepoint_dialect_getter_matches_for_test() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test_with_dialect(
        handles,
        1,
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
        SavepointDialect::SqlServer,
    );
    assert_eq!(txn.savepoint_dialect(), SavepointDialect::SqlServer);
}
#[test]
fn quoting_for_auto_uses_sql92_double_quote() {
    assert_eq!(
        quoting_for(SavepointDialect::Auto),
        crate::engine::identifier::IdentifierQuoting::DoubleQuote
    );
}
#[test]
fn resolve_savepoint_dialect_unknown_engine_uses_sql92() {
    use crate::engine::core::ENGINE_UNKNOWN;

    assert_eq!(
        super::super::resolve_savepoint_dialect_for_engine(ENGINE_UNKNOWN),
        SavepointDialect::Sql92
    );
}
#[test]
fn savepoint_create_sql92_emits_double_quoted_identifier() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test_with_dialect(
        handles,
        u32::MAX,
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
        SavepointDialect::Sql92,
    );
    validate_identifier("sp_ok").unwrap();
    let qname = quote_identifier("sp_ok", quoting_for(SavepointDialect::Sql92)).unwrap();
    let sql = format!("SAVEPOINT {qname}");
    assert_eq!(sql, "SAVEPOINT \"sp_ok\"");
    // Method fails on dispatch (no connection) after validation passes.
    assert!(txn.savepoint_create("sp_ok").is_err());
}
#[test]
fn savepoint_rollback_to_sqlserver_bracket_quoting() {
    validate_identifier("sp1").unwrap();
    let qname = quote_identifier("sp1", quoting_for(SavepointDialect::SqlServer)).unwrap();
    let sql = format!("ROLLBACK TRANSACTION {qname}");
    assert_eq!(sql, "ROLLBACK TRANSACTION [sp1]");
}
#[test]
fn resolve_savepoint_dialect_maps_non_sqlserver_engines_to_sql92() {
    use crate::engine::core::{
        ENGINE_DB2, ENGINE_MARIADB, ENGINE_MYSQL, ENGINE_ORACLE, ENGINE_POSTGRES, ENGINE_SNOWFLAKE,
        ENGINE_SQLITE, ENGINE_UNKNOWN,
    };

    for engine in [
        ENGINE_POSTGRES,
        ENGINE_MYSQL,
        ENGINE_MARIADB,
        ENGINE_DB2,
        ENGINE_ORACLE,
        ENGINE_SQLITE,
        ENGINE_SNOWFLAKE,
        ENGINE_UNKNOWN,
    ] {
        assert_eq!(
            super::super::resolve_savepoint_dialect_for_engine(engine),
            SavepointDialect::Sql92,
            "{engine} must use SQL-92 savepoint grammar"
        );
    }
}
#[test]
fn savepoint_auto_defensive_create_uses_savepoint_keyword() {
    validate_identifier("sp_auto").unwrap();
    let qname = quote_identifier("sp_auto", quoting_for(SavepointDialect::Auto)).unwrap();
    let sql = format!("SAVEPOINT {qname}");
    assert_eq!(sql, "SAVEPOINT \"sp_auto\"");
}
#[test]
fn savepoint_release_sql92_emits_release_savepoint() {
    validate_identifier("sp_rel").unwrap();
    let qname = quote_identifier("sp_rel", quoting_for(SavepointDialect::Sql92)).unwrap();
    let sql = format!("RELEASE SAVEPOINT {qname}");
    assert_eq!(sql, "RELEASE SAVEPOINT \"sp_rel\"");
}
#[test]
fn savepoint_rollback_to_sql92_uses_double_quoted_identifier() {
    validate_identifier("sp_rb").unwrap();
    let qname = quote_identifier("sp_rb", quoting_for(SavepointDialect::Sql92)).unwrap();
    let sql = format!("ROLLBACK TO SAVEPOINT {qname}");
    assert_eq!(sql, "ROLLBACK TO SAVEPOINT \"sp_rb\"");
}
#[test]
fn snowflake_savepoint_dialect_resolves_to_sql92_not_sqlserver() {
    use crate::engine::core::{ENGINE_SNOWFLAKE, ENGINE_SQLSERVER};

    assert_ne!(ENGINE_SNOWFLAKE, ENGINE_SQLSERVER);
    assert_eq!(
        super::super::resolve_savepoint_dialect_for_engine(ENGINE_SNOWFLAKE),
        SavepointDialect::Sql92
    );
    assert_eq!(
        super::super::resolve_savepoint_dialect_for_engine(ENGINE_SQLSERVER),
        SavepointDialect::SqlServer
    );
}
#[test]
fn quoting_for_sqlserver_uses_bracket_style() {
    assert_eq!(
        quoting_for(SavepointDialect::SqlServer),
        crate::engine::identifier::IdentifierQuoting::Brackets
    );
}
#[test]
fn savepoint_rollback_to_rejects_empty_name_on_sql92() {
    let txn = Transaction::for_test_no_conn(
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
        SavepointDialect::Sql92,
    );
    assert!(matches!(
        txn.savepoint_rollback_to(""),
        Err(OdbcError::ValidationError(_))
    ));
}

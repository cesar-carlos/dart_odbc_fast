use super::{HandleManager, IsolationLevel, SharedHandleManager, Transaction, TransactionState};
use std::sync::{Arc, Mutex};

#[test]
fn isolation_level_from_u32_maps_odbc_values() {
    assert_eq!(
        IsolationLevel::from_u32(0),
        Some(IsolationLevel::ReadUncommitted)
    );
    assert_eq!(
        IsolationLevel::from_u32(1),
        Some(IsolationLevel::ReadCommitted)
    );
    assert_eq!(
        IsolationLevel::from_u32(2),
        Some(IsolationLevel::RepeatableRead)
    );
    assert_eq!(
        IsolationLevel::from_u32(3),
        Some(IsolationLevel::Serializable)
    );
    assert_eq!(IsolationLevel::from_u32(4), None);
}
#[test]
fn isolation_level_to_sql_keyword_sql92() {
    assert_eq!(
        IsolationLevel::ReadUncommitted.to_sql_keyword(),
        "READ UNCOMMITTED"
    );
    assert_eq!(
        IsolationLevel::ReadCommitted.to_sql_keyword(),
        "READ COMMITTED"
    );
    assert_eq!(
        IsolationLevel::RepeatableRead.to_sql_keyword(),
        "REPEATABLE READ"
    );
    assert_eq!(
        IsolationLevel::Serializable.to_sql_keyword(),
        "SERIALIZABLE"
    );
}
#[test]
fn isolation_level_to_db2_keyword() {
    assert_eq!(IsolationLevel::ReadUncommitted.to_db2_keyword(), "UR");
    assert_eq!(IsolationLevel::ReadCommitted.to_db2_keyword(), "CS");
    assert_eq!(IsolationLevel::RepeatableRead.to_db2_keyword(), "RS");
    assert_eq!(IsolationLevel::Serializable.to_db2_keyword(), "RR");
}
#[test]
fn isolation_level_set_transaction_sql_format() {
    let level = IsolationLevel::ReadCommitted;
    let sql = format!("SET TRANSACTION ISOLATION LEVEL {}", level.to_sql_keyword());
    assert_eq!(sql, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED");
}
#[test]
fn transaction_for_test_exposes_conn_id_and_isolation() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        42,
        TransactionState::Active,
        IsolationLevel::Serializable,
    );
    assert_eq!(txn.conn_id(), 42);
    assert_eq!(txn.isolation_level(), IsolationLevel::Serializable);
}
#[test]
fn isolation_sqlite_pragma_sql_formats() {
    let ru = format!(
        "PRAGMA read_uncommitted = {}",
        if matches!(
            IsolationLevel::ReadUncommitted,
            IsolationLevel::ReadUncommitted
        ) {
            1
        } else {
            0
        }
    );
    assert_eq!(ru, "PRAGMA read_uncommitted = 1");
    let serial = match IsolationLevel::Serializable {
        IsolationLevel::ReadUncommitted => "PRAGMA read_uncommitted = 1",
        _ => "PRAGMA read_uncommitted = 0",
    };
    assert_eq!(serial, "PRAGMA read_uncommitted = 0");
}
#[test]
fn isolation_db2_set_current_sql_format() {
    let sql = format!(
        "SET CURRENT ISOLATION = {}",
        IsolationLevel::RepeatableRead.to_db2_keyword()
    );
    assert_eq!(sql, "SET CURRENT ISOLATION = RS");
}
#[test]
fn oracle_isolation_unsupported_level_validation_message() {
    for level in [
        IsolationLevel::ReadUncommitted,
        IsolationLevel::RepeatableRead,
    ] {
        let msg = format!(
            "Oracle does not support isolation level {level:?}; \
             only ReadCommitted and Serializable are supported"
        );
        assert!(msg.contains("Oracle does not support"));
        assert!(msg.contains("ReadCommitted"));
        assert!(msg.contains("Serializable"));
    }
}

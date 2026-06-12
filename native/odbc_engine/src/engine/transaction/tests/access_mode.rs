use super::{
    HandleManager, IsolationLevel, SavepointDialect, SharedHandleManager, Transaction,
    TransactionAccessMode, TransactionState,
};
use std::sync::{Arc, Mutex};

#[test]
fn transaction_access_mode_from_u32_default_is_read_write() {
    assert_eq!(
        TransactionAccessMode::from_u32(0),
        TransactionAccessMode::ReadWrite
    );
    assert_eq!(
        TransactionAccessMode::from_u32(99),
        TransactionAccessMode::ReadWrite,
        "unknown discriminants must default to ReadWrite (safe default)"
    );
}
#[test]
fn transaction_access_mode_from_u32_explicit_codes() {
    assert_eq!(
        TransactionAccessMode::from_u32(1),
        TransactionAccessMode::ReadOnly
    );
}
#[test]
fn transaction_access_mode_to_sql_keyword() {
    assert_eq!(
        TransactionAccessMode::ReadOnly.to_sql_keyword(),
        "READ ONLY"
    );
    assert_eq!(
        TransactionAccessMode::ReadWrite.to_sql_keyword(),
        "READ WRITE"
    );
}
#[test]
fn transaction_access_mode_is_read_only() {
    assert!(TransactionAccessMode::ReadOnly.is_read_only());
    assert!(!TransactionAccessMode::ReadWrite.is_read_only());
}
#[test]
fn transaction_defaults_to_read_write_access_mode() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        1,
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
    );
    assert_eq!(txn.access_mode(), TransactionAccessMode::ReadWrite);
}
#[test]
fn transaction_for_test_with_access_mode_stores_mode() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test_with_access_mode(
        handles,
        1,
        TransactionState::Active,
        IsolationLevel::Serializable,
        SavepointDialect::Sql92,
        TransactionAccessMode::ReadOnly,
    );
    assert_eq!(txn.access_mode(), TransactionAccessMode::ReadOnly);
    assert_eq!(txn.isolation_level(), IsolationLevel::Serializable);
}
#[test]
fn transaction_access_mode_sql_keyword_is_stable() {
    // Regression: keyword strings must match ODBC/SQL standard spellings.
    assert_eq!(
        TransactionAccessMode::ReadOnly.to_sql_keyword(),
        "READ ONLY"
    );
    assert_eq!(
        TransactionAccessMode::ReadWrite.to_sql_keyword(),
        "READ WRITE"
    );
}

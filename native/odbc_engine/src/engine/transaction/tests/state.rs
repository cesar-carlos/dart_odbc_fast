use super::{
    HandleManager, IsolationLevel, OdbcError, SavepointDialect, SharedHandleManager, Transaction,
    TransactionState,
};
use std::sync::{Arc, Mutex};

#[test]
fn transaction_commit_when_already_committed_returns_validation_error() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        1,
        TransactionState::Committed,
        IsolationLevel::ReadCommitted,
    );
    let result = txn.commit();
    match &result {
        Err(OdbcError::ValidationError(msg)) => assert!(msg.contains("Cannot commit")),
        _ => panic!("expected ValidationError, got {:?}", result),
    }
}
#[test]
fn transaction_rollback_when_already_rolled_back_returns_validation_error() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        1,
        TransactionState::RolledBack,
        IsolationLevel::ReadCommitted,
    );
    let result = txn.rollback();
    match &result {
        Err(OdbcError::ValidationError(msg)) => assert!(msg.contains("Cannot rollback")),
        _ => panic!("expected ValidationError, got {:?}", result),
    }
}
#[test]
fn transaction_state_variants() {
    let _ = TransactionState::None;
    let _ = TransactionState::Active;
    let _ = TransactionState::Committed;
    let _ = TransactionState::RolledBack;
}
#[test]
fn transaction_commit_when_already_rolled_back_returns_validation_error() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        1,
        TransactionState::RolledBack,
        IsolationLevel::ReadCommitted,
    );
    let result = txn.commit();
    match &result {
        Err(OdbcError::ValidationError(msg)) => assert!(msg.contains("Cannot commit")),
        _ => panic!("expected ValidationError, got {:?}", result),
    }
}
#[test]
fn transaction_commit_when_state_is_none_returns_validation_error() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        1,
        TransactionState::None,
        IsolationLevel::ReadCommitted,
    );
    let result = txn.commit();
    match &result {
        Err(OdbcError::ValidationError(msg)) => assert!(msg.contains("Cannot commit")),
        _ => panic!("expected ValidationError, got {:?}", result),
    }
}
#[test]
fn transaction_rollback_when_state_is_none_returns_validation_error() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        1,
        TransactionState::None,
        IsolationLevel::ReadCommitted,
    );
    let result = txn.rollback();
    match &result {
        Err(OdbcError::ValidationError(msg)) => assert!(msg.contains("Cannot rollback")),
        _ => panic!("expected ValidationError, got {:?}", result),
    }
}
#[test]
fn transaction_rollback_when_already_committed_returns_validation_error() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        1,
        TransactionState::Committed,
        IsolationLevel::ReadCommitted,
    );
    let result = txn.rollback();
    match &result {
        Err(OdbcError::ValidationError(msg)) => assert!(msg.contains("Cannot rollback")),
        _ => panic!("expected ValidationError, got {:?}", result),
    }
}
#[test]
fn transaction_is_active_true_when_active() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        1,
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
    );
    assert!(txn.is_active());
}
#[test]
fn transaction_is_active_false_when_committed() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        1,
        TransactionState::Committed,
        IsolationLevel::ReadCommitted,
    );
    assert!(!txn.is_active());
}
#[test]
fn transaction_is_active_false_when_rolled_back() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        1,
        TransactionState::RolledBack,
        IsolationLevel::ReadCommitted,
    );
    assert!(!txn.is_active());
}
#[test]
fn transaction_is_active_false_when_state_none() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        1,
        TransactionState::None,
        IsolationLevel::ReadCommitted,
    );
    assert!(!txn.is_active());
}
#[test]
fn transaction_handles_returns_shared_arc_from_for_test() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles.clone(),
        3,
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
    );
    assert!(Arc::ptr_eq(&handles, &txn.handles()));
}
#[test]
fn transaction_for_test_no_conn_validates_before_dispatch_on_release() {
    let txn = Transaction::for_test_no_conn(
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
        SavepointDialect::Sql92,
    );
    assert!(txn.savepoint_release("ok_name").is_err());
    assert!(matches!(
        txn.savepoint_release("bad;name"),
        Err(OdbcError::ValidationError(_))
    ));
}

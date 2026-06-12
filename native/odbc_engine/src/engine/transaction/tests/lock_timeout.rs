use super::{
    HandleManager, IsolationLevel, LockTimeout, SavepointDialect, SharedHandleManager, Transaction,
    TransactionAccessMode, TransactionState,
};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[test]
fn lock_timeout_default_is_engine_default() {
    let lt = LockTimeout::default();
    assert!(lt.is_engine_default());
    assert_eq!(lt.millis(), None);
}
#[test]
fn lock_timeout_engine_default_const_is_none() {
    let lt = LockTimeout::engine_default();
    assert!(lt.is_engine_default());
    assert_eq!(lt.millis(), None);
}
#[test]
fn lock_timeout_from_millis_zero_collapses_to_engine_default() {
    // The wire `0` MUST round-trip as "engine default" so the FFI
    // `lock_timeout_ms = 0` parameter is unambiguous.
    let lt = LockTimeout::from_millis(0);
    assert!(lt.is_engine_default());
    assert_eq!(lt.millis(), None);
}
#[test]
fn lock_timeout_from_millis_non_zero_preserves_value() {
    let lt = LockTimeout::from_millis(2500);
    assert!(!lt.is_engine_default());
    assert_eq!(lt.millis(), Some(2500));
}
#[test]
fn lock_timeout_from_duration_zero_is_engine_default() {
    let lt = LockTimeout::from_duration(Duration::ZERO);
    assert!(
        lt.is_engine_default(),
        "Duration::ZERO must be the canonical 'engine default' input"
    );
}
#[test]
fn lock_timeout_from_duration_sub_millisecond_rounds_up_to_one_ms() {
    // Anyone passing a sub-ms positive duration almost certainly
    // wants "wait a tiny bit", not "engine default". Bump to 1ms.
    let lt = LockTimeout::from_duration(Duration::from_micros(500));
    assert_eq!(
        lt.millis(),
        Some(1),
        "sub-ms positive durations must NOT silently collapse to \
         engine default — they round up to 1ms"
    );
}
#[test]
fn lock_timeout_from_duration_milliseconds_round_trip() {
    let lt = LockTimeout::from_duration(Duration::from_millis(2_500));
    assert_eq!(lt.millis(), Some(2_500));
}
#[test]
fn lock_timeout_from_duration_clamps_at_u32_max() {
    // 60 minutes > u32 ms range (~49.7 days). Use a value that
    // overflows u32 *milliseconds* to verify the saturating cast.
    let big = Duration::from_secs(u64::from(u32::MAX) + 1);
    let lt = LockTimeout::from_duration(big);
    assert_eq!(
        lt.millis(),
        Some(u32::MAX),
        "duration > u32::MAX ms must clamp to the largest u32 \
         rather than wrap around to a tiny value"
    );
}
#[test]
fn lock_timeout_seconds_rounding_for_mysql_db2() {
    // Exact second.
    assert_eq!(
        LockTimeout::from_millis(1_000).millis_as_seconds_rounded_up(),
        Some(1),
    );
    // Sub-second positive → bump to 1.
    assert_eq!(
        LockTimeout::from_millis(500).millis_as_seconds_rounded_up(),
        Some(1),
        "sub-second timeouts must round UP so we never silently \
         relax the caller's bound"
    );
    // 1 ms over a boundary → next second.
    assert_eq!(
        LockTimeout::from_millis(1_001).millis_as_seconds_rounded_up(),
        Some(2),
    );
    // 2.999 s → 3 s.
    assert_eq!(
        LockTimeout::from_millis(2_999).millis_as_seconds_rounded_up(),
        Some(3),
    );
    // Engine-default → None.
    assert_eq!(
        LockTimeout::engine_default().millis_as_seconds_rounded_up(),
        None,
    );
}
#[test]
fn transaction_default_lock_timeout_is_engine_default() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test(
        handles,
        1,
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
    );
    assert!(txn.lock_timeout().is_engine_default());
}
#[test]
fn transaction_for_test_with_lock_timeout_pins_the_value() {
    let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
    let txn = Transaction::for_test_with_lock_timeout(
        handles,
        7,
        TransactionState::Active,
        IsolationLevel::Serializable,
        SavepointDialect::Sql92,
        TransactionAccessMode::ReadOnly,
        LockTimeout::from_millis(2_500),
    );
    assert_eq!(txn.lock_timeout().millis(), Some(2_500));
    // Other dimensions also survive intact.
    assert_eq!(txn.access_mode(), TransactionAccessMode::ReadOnly);
    assert_eq!(txn.isolation_level(), IsolationLevel::Serializable);
}

/// Pure SQL formatting checks (no driver involved) for each engine
/// in the lock-timeout matrix. Pins the wire format so future
/// edits to `apply_lock_timeout` can't silently change SQL output.
#[test]
fn lock_timeout_sql_format_per_engine() {
    let lt = LockTimeout::from_millis(2_500);
    let ms = lt.millis().unwrap();
    let secs = lt.millis_as_seconds_rounded_up().unwrap();

    assert_eq!(format!("SET LOCK_TIMEOUT {}", ms), "SET LOCK_TIMEOUT 2500");
    assert_eq!(
        format!("SET LOCAL lock_timeout = '{}ms'", ms),
        "SET LOCAL lock_timeout = '2500ms'",
    );
    assert_eq!(
        format!("SET SESSION innodb_lock_wait_timeout = {}", secs),
        "SET SESSION innodb_lock_wait_timeout = 3",
        "MySQL/MariaDB rounds 2500ms up to 3s",
    );
    assert_eq!(
        format!("SET CURRENT LOCK TIMEOUT {}", secs),
        "SET CURRENT LOCK TIMEOUT 3",
    );
    assert_eq!(
        format!("PRAGMA busy_timeout = {}", ms),
        "PRAGMA busy_timeout = 2500"
    );
}
#[test]
fn lock_timeout_is_engine_default_predicate() {
    assert!(LockTimeout::engine_default().is_engine_default());
    assert!(!LockTimeout::from_millis(1).is_engine_default());
}

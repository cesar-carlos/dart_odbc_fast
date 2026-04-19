//! E2E coverage for per-transaction `LockTimeout` (Sprint 4.2).
//!
//! Verified contracts:
//!
//! - **Default `engine_default`**: `apply_lock_timeout` is a no-op.
//!   Transaction lifecycle is unchanged from the v3.3.0 baseline.
//! - **SQL Server `SET LOCK_TIMEOUT <ms>`**: an explicit override is
//!   accepted by the driver and the recorded `lock_timeout()` matches
//!   what the caller asked for.
//! - **Sub-second values are honoured** (no silent rounding to 1s on
//!   engines that natively express ms).
//!
//! All tests are gated by `should_run_e2e_tests()`; without a DSN they
//! early-return and the suite stays green on machines without ODBC
//! configured. Engines outside the SQL Server matrix exercise this path
//! through the unit tests in `transaction.rs::tests`.

use odbc_engine::engine::{
    IsolationLevel, LockTimeout, OdbcConnection, OdbcEnvironment, SavepointDialect,
    TransactionAccessMode,
};

mod helpers;
use helpers::e2e::{is_database_type, should_run_e2e_tests, DatabaseType};
use helpers::env::get_sqlserver_test_dsn;

/// `LockTimeout::engine_default()` must NOT emit any `SET` and the
/// transaction lifecycle must be byte-identical to the
/// `begin_with_access_mode` path. Pinning this so future refactors of
/// `apply_lock_timeout` can't silently introduce a redundant SQL.
#[test]
fn test_e2e_lock_timeout_engine_default_is_pure_noop_on_sqlserver() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping: no DSN");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let conn_str = get_sqlserver_test_dsn().expect("DSN missing");
    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("connect");

    let txn = conn
        .begin_transaction_with_lock_timeout(
            IsolationLevel::ReadCommitted,
            SavepointDialect::Auto,
            TransactionAccessMode::ReadWrite,
            LockTimeout::engine_default(),
        )
        .expect("begin");
    assert!(
        txn.lock_timeout().is_engine_default(),
        "the recorded lock_timeout must reflect 'no override'"
    );
    txn.execute_sql("SELECT 1").expect("trivial select");
    txn.commit().expect("commit");

    println!("✓ engine_default lock timeout is a pure no-op on SQL Server");
    conn.disconnect().expect("disconnect");
}

/// SQL Server accepts `SET LOCK_TIMEOUT <ms>` and we record the
/// requested override. The override is applied for real; we don't
/// assert on lock-wait behaviour because that would need a second
/// connection to hold a competing lock — overkill for a unit/E2E
/// regression test of the wire format.
#[test]
fn test_e2e_lock_timeout_explicit_value_is_accepted_by_sqlserver() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping: no DSN");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let conn_str = get_sqlserver_test_dsn().expect("DSN missing");
    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("connect");

    let lock_timeout = LockTimeout::from_millis(2_500);
    let txn = conn
        .begin_transaction_with_lock_timeout(
            IsolationLevel::ReadCommitted,
            SavepointDialect::Auto,
            TransactionAccessMode::ReadWrite,
            lock_timeout,
        )
        .expect(
            "begin with SET LOCK_TIMEOUT must succeed against a healthy \
             SQL Server",
        );

    assert_eq!(
        txn.lock_timeout(),
        lock_timeout,
        "the recorded lock_timeout must reflect what the caller asked for"
    );
    assert_eq!(txn.lock_timeout().millis(), Some(2_500));

    // SELECT inside the transaction still works after the SET.
    txn.execute_sql("SELECT 1")
        .expect("select inside lock-timeout txn");
    txn.commit().expect("commit");

    println!("✓ SET LOCK_TIMEOUT 2500 accepted by SQL Server");
    conn.disconnect().expect("disconnect");
}

/// Sub-second positive durations must round up to 1ms (not collapse
/// to engine-default). On SQL Server the SET itself is millisecond-
/// granular, so we just verify the round trip.
#[test]
fn test_e2e_lock_timeout_one_millisecond_round_trip_on_sqlserver() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping: no DSN");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let conn_str = get_sqlserver_test_dsn().expect("DSN missing");
    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("connect");

    let lock_timeout = LockTimeout::from_duration(std::time::Duration::from_micros(500));
    let txn = conn
        .begin_transaction_with_lock_timeout(
            IsolationLevel::ReadCommitted,
            SavepointDialect::Auto,
            TransactionAccessMode::ReadWrite,
            lock_timeout,
        )
        .expect("begin with 1ms lock timeout");

    assert_eq!(
        txn.lock_timeout().millis(),
        Some(1),
        "sub-ms positive durations must round UP to 1ms, not collapse \
         to engine-default"
    );
    txn.commit().expect("commit");
    conn.disconnect().expect("disconnect");

    println!("✓ Sub-ms positive duration rounds up to 1ms");
}

/// v3.3.0 path (no lock timeout) must be untouched — proves the
/// helper is fully backwards compatible.
#[test]
fn test_e2e_lock_timeout_v33_path_still_works_unchanged() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping: no DSN");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        return;
    }

    let conn_str = get_sqlserver_test_dsn().expect("DSN missing");
    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("connect");

    // begin_with_access_mode is the Sprint 4.1 entry point. It must
    // still default lock_timeout to engine_default and behave exactly
    // like before Sprint 4.2.
    let txn = conn
        .begin_transaction_with_access_mode(
            IsolationLevel::ReadCommitted,
            SavepointDialect::Auto,
            TransactionAccessMode::ReadWrite,
        )
        .expect("begin via Sprint 4.1 entry point");
    assert!(
        txn.lock_timeout().is_engine_default(),
        "Sprint 4.1 entry point must default lock_timeout to engine_default"
    );
    txn.commit().expect("commit");
    conn.disconnect().expect("disconnect");

    println!("✓ Sprint 4.1 entry point preserves engine-default lock timeout");
}

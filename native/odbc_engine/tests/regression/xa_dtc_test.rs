//! MSDTC + SQL Server XA integration (Sprint 4.3b Phase 2).
//!
//! Requires:
//! - Windows host with `sc query MSDTC` → `RUNNING`
//! - `ENABLE_E2E_TESTS=1` and a SQL Server DSN (see repository
//!   `doc/development/msdtc-recovery.md`, *Local runbook*).
//! - Build / run: from `native`, e.g. `cargo test -p odbc_engine --features
//!   xa-dtc --test regression_test xa_dtc_sqlserver_ -- --ignored
//!   --test-threads=1` to run both tests: `…_lifecycle_smoke` (prepare then
//!   **rollback**) and `…_prepare_commit_smoke` (prepare then **commit**). Or
//!   pass a full test name to run one.
//!
//! Not run in Linux CI.

use odbc_engine::engine::{OdbcConnection, OdbcEnvironment, PreparedXa, XaTransaction, Xid};

#[path = "../helpers/mod.rs"]
mod helpers;
use helpers::e2e::should_run_e2e_tests;
use helpers::env::get_sqlserver_test_dsn;

#[test]
#[ignore = "Windows+MSDTC+SQL Server; ENABLE_E2E_TESTS=1 + DSN; see doc/development/msdtc-recovery.md Local runbook"]
fn xa_dtc_sqlserver_lifecycle_smoke() {
    if !should_run_e2e_tests() {
        eprintln!("Skipping: ENABLE_E2E_TESTS not set or DSN unavailable");
        return;
    }
    let conn_str = match get_sqlserver_test_dsn() {
        Some(s) => s,
        None => {
            eprintln!("Skipping: no SQL Server DSN");
            return;
        }
    };

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");
    let conn_id = conn.get_connection_id();

    let xid = Xid::new(1, b"dtc-smoke-gtrid".to_vec(), b"br".to_vec()).expect("xid");

    let xa = XaTransaction::start(handles.clone(), conn_id, xid).expect("xa_start");
    let prep = xa.end().expect("xa_end");
    let ready: PreparedXa = prep.prepare().expect("xa_prepare");
    // Clean up: rollback prepared state so the server/MSDTC are not left dangling.
    ready.rollback().expect("xa_rollback");
    conn.disconnect().expect("disconnect");
}

/// Phase 2 *commit* after *prepare* (DTC *happy path*); uses a distinct [Xid]
/// from [xa_dtc_sqlserver_lifecycle_smoke].
#[test]
#[ignore = "Windows+MSDTC+SQL Server; ENABLE_E2E_TESTS=1 + DSN; see doc/development/msdtc-recovery.md Local runbook"]
fn xa_dtc_sqlserver_prepare_commit_smoke() {
    if !should_run_e2e_tests() {
        eprintln!("Skipping: ENABLE_E2E_TESTS not set or DSN unavailable");
        return;
    }
    let conn_str = match get_sqlserver_test_dsn() {
        Some(s) => s,
        None => {
            eprintln!("Skipping: no SQL Server DSN");
            return;
        }
    };

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");
    let conn_id = conn.get_connection_id();

    let xid = Xid::new(1, b"dtc-commit-gtrid".to_vec(), b"br-commit".to_vec()).expect("xid");

    let xa = XaTransaction::start(handles.clone(), conn_id, xid).expect("xa_start");
    let prep = xa.end().expect("xa_end");
    let ready: PreparedXa = prep.prepare().expect("xa_prepare");
    ready.commit().expect("xa_commit");
    conn.disconnect().expect("disconnect");
}

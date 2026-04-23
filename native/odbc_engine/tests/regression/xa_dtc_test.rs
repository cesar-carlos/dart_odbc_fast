//! MSDTC + SQL Server XA integration (Sprint 4.3b Phase 2).
//!
//! Requires:
//! - Windows host with `sc query MSDTC` → `RUNNING`
//! - SQL Server reachable with the DSN from `SQLSERVER_TEST_*` / `ODBC_TEST_DSN`
//! - Build: `cargo test -p odbc_engine --features xa-dtc -- --ignored --test-threads=1`
//!
//! Not run in Linux CI.

use odbc_engine::engine::{OdbcConnection, OdbcEnvironment, PreparedXa, XaTransaction, Xid};

#[path = "../helpers/mod.rs"]
mod helpers;
use helpers::e2e::should_run_e2e_tests;
use helpers::env::get_sqlserver_test_dsn;

#[test]
#[ignore = "Requires Windows + MSDTC + SQL Server; run locally with ENABLE_E2E_TESTS=1"]
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

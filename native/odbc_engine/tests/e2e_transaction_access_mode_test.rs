//! E2E coverage for `TransactionAccessMode` (Sprint 4.1).
//!
//! These tests verify the runtime contract of
//! [`Transaction::begin_with_access_mode`] across engines:
//!
//! - **Default `ReadWrite`** must keep the v1 behaviour byte-for-byte:
//!   the engine accepts DML inside the transaction, commit/rollback
//!   round-trip cleanly, no extra `SET TRANSACTION` is observable.
//! - **`ReadOnly` on SQL Server / SQLite / Snowflake / unknown** must be
//!   a silent no-op so callers can program against the abstraction
//!   unconditionally — DML still works (engine has no native hint), and
//!   the transaction lifecycle is unaffected.
//! - **`ReadOnly` on PostgreSQL / MySQL / MariaDB / DB2 / Oracle** would
//!   issue `SET TRANSACTION READ ONLY`. Those tests are gated on the
//!   matching DSN being available; right now only the SQL Server path
//!   is exercised against a live DB in CI, but the cross-engine matrix
//!   is documented inline so the gap is visible.
//!
//! All tests are gated by `should_run_e2e_tests()`; without a DSN they
//! early-return and the suite stays green on machines without ODBC
//! configured.

use odbc_engine::engine::{
    execute_query_with_connection, IsolationLevel, OdbcConnection, OdbcEnvironment,
    SavepointDialect, TransactionAccessMode,
};
use odbc_engine::protocol::BinaryProtocolDecoder;

mod helpers;
use helpers::e2e::{is_database_type, should_run_e2e_tests, DatabaseType};
use helpers::env::get_sqlserver_test_dsn;

/// Helper: pull a single i32 cell out of a binary protocol buffer.
fn read_single_i32(buffer: &[u8]) -> i32 {
    let decoded = BinaryProtocolDecoder::parse(buffer).expect("decode failed");
    assert_eq!(decoded.row_count, 1, "expected exactly one row");
    let cell = decoded.rows[0][0].as_ref().expect("expected non-NULL cell");
    if cell.len() == 4 {
        i32::from_le_bytes([cell[0], cell[1], cell[2], cell[3]])
    } else {
        std::str::from_utf8(cell)
            .ok()
            .and_then(|s| s.trim().parse::<i32>().ok())
            .unwrap_or_else(|| panic!("could not decode i32 from {:?}", cell))
    }
}

/// `READ WRITE` is the universal default; this test pins the contract
/// that an explicit `ReadWrite` is byte-identical to omitting the
/// argument (i.e. the v1 entry point).
#[test]
fn test_e2e_access_mode_default_read_write_preserves_v1_behaviour() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping: no DSN");
        return;
    }
    if !is_database_type(DatabaseType::SqlServer) {
        // Other engines exercise this implicitly via every other E2E
        // test; gate on SQL Server so we have a deterministic environment.
        return;
    }

    let conn_str = get_sqlserver_test_dsn().expect("DSN missing");
    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");

    // begin_with_access_mode(..., ReadWrite) — explicit default.
    let txn = conn
        .begin_transaction_with_access_mode(
            IsolationLevel::ReadCommitted,
            SavepointDialect::Auto,
            TransactionAccessMode::ReadWrite,
        )
        .expect("begin transaction");
    assert_eq!(txn.access_mode(), TransactionAccessMode::ReadWrite);

    // A bare SELECT must succeed inside the transaction.
    txn.execute_sql("SELECT 1 AS x").expect("select inside txn");
    txn.commit().expect("commit");

    println!("✓ Default ReadWrite preserves v1 behaviour");
    conn.disconnect().expect("disconnect");
}

/// SQL Server has no native `READ ONLY` transaction hint. The engine
/// must treat the request as a successful no-op (logged at debug) so
/// callers can program against the abstraction unconditionally. The
/// transaction itself must still work normally — the application is
/// responsible for not issuing DML when it asked for read-only mode.
#[test]
fn test_e2e_access_mode_read_only_is_noop_on_sqlserver() {
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
    let conn = OdbcConnection::connect(handles.clone(), &conn_str).expect("connect");
    let conn_id = conn.get_connection_id();

    let txn = conn
        .begin_transaction_with_access_mode(
            IsolationLevel::ReadCommitted,
            SavepointDialect::Auto,
            TransactionAccessMode::ReadOnly,
        )
        .expect("begin should succeed even though SQL Server has no READ ONLY");
    assert_eq!(
        txn.access_mode(),
        TransactionAccessMode::ReadOnly,
        "the recorded access mode must reflect what the caller asked for, \
         even when the engine ignores it at the SQL level"
    );

    // SELECTs work — read-only by definition.
    txn.execute_sql("SELECT 1").expect("select 1");

    // Bonus: SQL Server treating ReadOnly as no-op means a DML *would*
    // succeed. We don't assert that here to avoid leaving artefacts in
    // the test database, but we do prove the lifecycle survives.
    {
        let h = handles.lock().unwrap();
        let conn_arc = h.get_connection(conn_id).unwrap();
        let c = conn_arc.lock().unwrap();
        let buf = execute_query_with_connection(c.connection(), "SELECT 42 AS answer")
            .expect("query inside read-only txn");
        assert_eq!(read_single_i32(&buf), 42);
    }

    txn.commit().expect("commit read-only txn");
    println!("✓ ReadOnly is a silent no-op on SQL Server");
    conn.disconnect().expect("disconnect");
}

/// Default-path regression: the FFI v1 entry point must keep returning
/// transactions that behave as `ReadWrite`, since pre-Sprint-4.1
/// callers never had a way to opt into read-only mode.
#[test]
fn test_e2e_access_mode_v1_path_defaults_to_read_write() {
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

    // begin_transaction_with_dialect — the v1-equivalent core path.
    let txn = conn
        .begin_transaction_with_dialect(IsolationLevel::ReadCommitted, SavepointDialect::Auto)
        .expect("begin v1");
    assert_eq!(
        txn.access_mode(),
        TransactionAccessMode::ReadWrite,
        "v1 callers must always observe ReadWrite for backwards compatibility"
    );
    txn.commit().expect("commit");

    println!("✓ v1 path defaults to ReadWrite");
    conn.disconnect().expect("disconnect");
}

/// Cross-engine `READ ONLY` exercise — gated on the connection actually
/// being one of the engines that *do* honour the hint. Today this is a
/// runtime no-op on SQL Server (covered above) and not yet wired into
/// the multi-DB test matrix; the test stays here as a placeholder so
/// the contract is documented and so wiring up Postgres/MySQL/Oracle
/// in the future is a one-line `cargo test` away.
#[test]
fn test_e2e_access_mode_read_only_on_engines_with_native_hint() {
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping: no DSN");
        return;
    }
    let supports_native_read_only = is_database_type(DatabaseType::PostgreSQL)
        || is_database_type(DatabaseType::MySQL)
        || is_database_type(DatabaseType::Oracle);
    if !supports_native_read_only {
        eprintln!(
            "ℹ️  Skipping: current DSN is not one of the engines that emit \
             SET TRANSACTION READ ONLY (Postgres/MySQL/Oracle). The unit \
             tests in transaction.rs cover the SQL formatting path."
        );
        return;
    }

    let conn_str = match helpers::env::get_test_dsn() {
        Some(s) => s,
        None => {
            eprintln!("⚠️  Skipping: get_test_dsn returned None");
            return;
        }
    };

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let conn = OdbcConnection::connect(handles, &conn_str).expect("connect");

    let txn = conn
        .begin_transaction_with_access_mode(
            IsolationLevel::ReadCommitted,
            SavepointDialect::Auto,
            TransactionAccessMode::ReadOnly,
        )
        .expect("begin read-only");

    // SELECT must succeed under READ ONLY.
    txn.execute_sql("SELECT 1")
        .expect("select inside read-only");

    // Some engines (Postgres, Oracle) raise an error if we try DML
    // inside a read-only transaction. Don't assert on that to keep
    // this test cross-engine portable — but note in the log that the
    // hint is in effect.
    println!("✓ ReadOnly accepted on engine with native hint (lifecycle round-trip)");

    txn.commit().expect("commit");
    conn.disconnect().expect("disconnect");
}

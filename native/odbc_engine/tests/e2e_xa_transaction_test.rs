//! E2E coverage for X/Open XA / 2PC transactions — Sprint 4.3.
//!
//! Each engine has its own gating helper: PostgreSQL tests run when
//! [`get_postgresql_test_dsn`] returns `Some`, MySQL tests run when
//! [`get_mysql_test_dsn`] returns `Some`. SQL Server (MSDTC) and optional
//! OCI XA paths are documented in `doc/Features/PENDING_IMPLEMENTATIONS.md`.
//! Oracle live tests here use the supported `DBMS_XA` stack when a DSN is
//! available. Engines without XA (e.g. SQLite) are covered by
//! `UnsupportedFeature` shims in `xa_transaction.rs::tests`.
//!
//! The test pattern for the live engines is the canonical 2PC
//! lifecycle:
//!
//! ```text
//! xa_start --> INSERT --> xa_end --> xa_prepare --> xa_commit
//! ```
//!
//! ...with a separate test for the rollback path, the 1RM commit-one-
//! phase shortcut, and the recovery flow (`xa_recover` ->
//! `resume_prepared` -> `xa_commit_prepared`).

use odbc_engine::engine::{
    recover_prepared_xids, resume_prepared, OdbcConnection, OdbcEnvironment, SharedHandleManager,
    XaTransaction, Xid,
};

mod helpers;
use helpers::env::{get_mysql_test_dsn, get_oracle_test_dsn, get_postgresql_test_dsn};

/// Build a unique XID per test so a failed run can't poison
/// subsequent ones (PG keeps prepared xacts across reconnects).
fn unique_xid(label: &str) -> Xid {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let gtrid = format!("{label}-{nanos}").into_bytes();
    Xid::new(0, gtrid, b"branch-A".to_vec()).expect("Xid::new must accept this shape")
}

/// Try to connect to the engine identified by `engine_label`. Returns
/// `None` (with a friendly skip log) when the DSN doesn't resolve to
/// a working driver — which is the common case in dev environments
/// (and CI runners) that only have a subset of engines installed.
///
/// Driver-not-found surfaces with three distinct shapes across the
/// driver managers we target:
///
/// - **Windows ODBC DM** -> SQLSTATE `IM002` ("Data source name not
///   found and no default driver specified").
/// - **unixODBC**        -> SQLSTATE `01000` plus a body containing
///   `Can't open lib ... : file not found`.
/// - **iODBC**           -> similar to unixODBC; we match the same
///   `Can't open lib` substring.
///
/// Any error that doesn't fit one of those patterns is re-raised so
/// genuine driver bugs don't silently pass the test gate.
///
/// Accepts the env via a fresh [`OdbcEnvironment`] to avoid leaking
/// the private `SharedHandleManager` type at the test surface.
fn try_connect(env: &OdbcEnvironment, dsn: &str, engine_label: &str) -> Option<OdbcConnection> {
    match OdbcConnection::connect(env.get_handles(), dsn) {
        Ok(c) => Some(c),
        Err(e) => {
            let msg = format!("{e}");
            let is_driver_missing = msg.contains("IM002")
                || (msg.contains("01000") && msg.contains("Can't open lib"))
                || msg.contains("file not found");
            if is_driver_missing {
                eprintln!(
                    "[SKIP] {engine_label} ODBC driver not installed: {}",
                    msg.lines().next().unwrap_or("").trim(),
                );
                None
            } else {
                panic!("connect to {engine_label}: unexpected error: {msg}");
            }
        }
    }
}

// =========================================================================
// PostgreSQL
// =========================================================================

#[test]
fn test_e2e_xa_postgresql_full_2pc_commit_path() {
    let Some(conn_str) = get_postgresql_test_dsn() else {
        eprintln!("[SKIP] PostgreSQL DSN not configured");
        return;
    };

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let Some(conn) = try_connect(&env, &conn_str, "PostgreSQL") else {
        return;
    };
    let conn_id = conn.get_connection_id();

    let xid = unique_xid("pg-2pc-commit");
    let xa = XaTransaction::start(handles.clone(), conn_id, xid.clone())
        .expect("xa_start (PostgreSQL: BEGIN)");

    let preparing = xa.end().expect("xa_end (PostgreSQL no-op)");
    let prepared = preparing
        .prepare()
        .expect("xa_prepare (PG: PREPARE TRANSACTION)");

    // The XID must show up in pg_prepared_xacts now.
    let recovered =
        recover_prepared_xids(handles.clone(), conn_id).expect("xa_recover must succeed");
    assert!(
        recovered.iter().any(|x| x == &xid),
        "xid must appear in pg_prepared_xacts after PREPARE; recovered: {:?}",
        recovered,
    );

    prepared.commit().expect("xa_commit_prepared");

    // Post-commit it must be gone.
    let after = recover_prepared_xids(handles, conn_id).expect("post-commit recover");
    assert!(
        !after.iter().any(|x| x == &xid),
        "xid must NOT appear in pg_prepared_xacts after COMMIT PREPARED",
    );

    println!("OK PostgreSQL full 2PC commit lifecycle round-trip");
    conn.disconnect().expect("disconnect");
}

#[test]
fn test_e2e_xa_postgresql_rollback_prepared_path() {
    let Some(conn_str) = get_postgresql_test_dsn() else {
        eprintln!("[SKIP] PostgreSQL DSN not configured");
        return;
    };

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let Some(conn) = try_connect(&env, &conn_str, "PostgreSQL") else {
        return;
    };
    let conn_id = conn.get_connection_id();

    let xid = unique_xid("pg-2pc-rollback");
    let xa = XaTransaction::start(handles.clone(), conn_id, xid.clone()).expect("xa_start");
    let preparing = xa.end().expect("xa_end");
    let prepared = preparing.prepare().expect("xa_prepare");

    prepared.rollback().expect("xa_rollback_prepared");

    let after = recover_prepared_xids(handles, conn_id).expect("post-rollback recover");
    assert!(
        !after.iter().any(|x| x == &xid),
        "xid must be gone after ROLLBACK PREPARED",
    );

    println!("OK PostgreSQL ROLLBACK PREPARED clears pg_prepared_xacts");
    conn.disconnect().expect("disconnect");
}

#[test]
fn test_e2e_xa_postgresql_one_phase_commit_shortcut() {
    let Some(conn_str) = get_postgresql_test_dsn() else {
        eprintln!("[SKIP] PostgreSQL DSN not configured");
        return;
    };

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let Some(conn) = try_connect(&env, &conn_str, "PostgreSQL") else {
        return;
    };
    let conn_id = conn.get_connection_id();

    let xid = unique_xid("pg-1rm-commit");
    let xa = XaTransaction::start(handles.clone(), conn_id, xid.clone()).expect("xa_start");

    // 1RM optimisation: skip prepare -> straight commit.
    xa.commit_one_phase()
        .expect("commit_one_phase (PG: plain COMMIT)");

    // Must not appear in pg_prepared_xacts (no PREPARE was emitted).
    let after = recover_prepared_xids(handles, conn_id).expect("recover");
    assert!(
        !after.iter().any(|x| x == &xid),
        "1RM commit must NOT leave a prepared entry",
    );

    println!("OK PostgreSQL commit_one_phase skips PREPARE");
    conn.disconnect().expect("disconnect");
}

#[test]
fn test_e2e_xa_postgresql_resume_prepared_after_disconnect() {
    let Some(conn_str) = get_postgresql_test_dsn() else {
        eprintln!("[SKIP] PostgreSQL DSN not configured");
        return;
    };

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();

    // First connection: prepare and disconnect without committing.
    let Some(conn1) = try_connect(&env, &conn_str, "PostgreSQL") else {
        return;
    };
    let xid = {
        let conn = conn1;
        let conn_id = conn.get_connection_id();
        let xid = unique_xid("pg-resume");
        let xa = XaTransaction::start(handles.clone(), conn_id, xid.clone()).expect("xa_start");
        let preparing = xa.end().expect("xa_end");
        let _prepared = preparing.prepare().expect("xa_prepare");
        // Drop _prepared without commit: PG keeps the prepared xact
        // because PREPARE TRANSACTION's outcome outlives the session.
        conn.disconnect().expect("disconnect 1");
        xid
    };

    // Second connection: recover + commit.
    {
        let Some(conn) = try_connect(&env, &conn_str, "PostgreSQL") else {
            return;
        };
        let conn_id = conn.get_connection_id();

        let recovered =
            recover_prepared_xids(handles.clone(), conn_id).expect("recover on a fresh connection");
        assert!(
            recovered.iter().any(|x| x == &xid),
            "xid prepared on connection 1 must show up on connection 2; \
             recovered: {:?}",
            recovered,
        );

        let prepared = resume_prepared(handles.clone(), conn_id, xid.clone())
            .expect("resume_prepared rebuilds the handle");
        prepared.commit().expect("commit after recovery");

        let after = recover_prepared_xids(handles, conn_id).expect("post-commit recover");
        assert!(
            !after.iter().any(|x| x == &xid),
            "xid must be gone after recovery commit",
        );

        conn.disconnect().expect("disconnect 2");
    }

    println!("OK PostgreSQL prepared XID survives disconnect and is recoverable");
}

// =========================================================================
// MySQL / MariaDB
// =========================================================================

#[test]
fn test_e2e_xa_mysql_full_2pc_commit_path() {
    let Some(conn_str) = get_mysql_test_dsn() else {
        eprintln!("[SKIP] MySQL DSN not configured");
        return;
    };

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let Some(conn) = try_connect(&env, &conn_str, "MySQL") else {
        return;
    };
    let conn_id = conn.get_connection_id();

    let xid = unique_xid("mysql-2pc-commit");
    let xa = XaTransaction::start(handles.clone(), conn_id, xid.clone())
        .expect("xa_start (MySQL: XA START)");
    let preparing = xa.end().expect("xa_end (MySQL: XA END)");
    let prepared = preparing.prepare().expect("xa_prepare (MySQL: XA PREPARE)");

    let recovered =
        recover_prepared_xids(handles.clone(), conn_id).expect("XA RECOVER must succeed");
    assert!(
        recovered.iter().any(|x| x == &xid),
        "xid must appear in XA RECOVER after XA PREPARE; recovered: {:?}",
        recovered,
    );

    prepared
        .commit()
        .expect("xa_commit_prepared (MySQL: XA COMMIT)");

    let after = recover_prepared_xids(handles, conn_id).expect("post-commit recover");
    assert!(
        !after.iter().any(|x| x == &xid),
        "xid must NOT appear in XA RECOVER after XA COMMIT",
    );

    println!("OK MySQL full 2PC commit lifecycle round-trip");
    conn.disconnect().expect("disconnect");
}

#[test]
fn test_e2e_xa_mysql_one_phase_commit_shortcut() {
    let Some(conn_str) = get_mysql_test_dsn() else {
        eprintln!("[SKIP] MySQL DSN not configured");
        return;
    };

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let Some(conn) = try_connect(&env, &conn_str, "MySQL") else {
        return;
    };
    let conn_id = conn.get_connection_id();

    let xid = unique_xid("mysql-1rm-commit");
    let xa = XaTransaction::start(handles.clone(), conn_id, xid.clone()).expect("xa_start");
    xa.commit_one_phase()
        .expect("commit_one_phase (MySQL: XA COMMIT ... ONE PHASE)");

    let after = recover_prepared_xids(handles, conn_id).expect("recover");
    assert!(
        !after.iter().any(|x| x == &xid),
        "1RM commit must NOT leave a prepared entry on MySQL",
    );

    println!("OK MySQL commit_one_phase emits XA COMMIT ... ONE PHASE");
    conn.disconnect().expect("disconnect");
}

// =========================================================================
// Oracle (DBMS_XA PL/SQL package — Sprint 4.3c Phase 2)
// =========================================================================
//
// Oracle XA flows through `apply_xa_*` via PL/SQL calls into the
// `SYS.DBMS_XA` package. The path validates the wiring sandboxed in
// the docker test-runner-oracle service. Skipped silently when the
// configured DSN is not Oracle (most dev boxes only run one engine
// at a time).

/// True when the DSN string is recognisably Oracle. `get_oracle_test_dsn`
/// is permissive (falls back to ODBC_TEST_DSN), so we double-gate
/// here to avoid running PL/SQL against a SQL-Server-only dev box.
fn dsn_targets_oracle(dsn: &str) -> bool {
    let lower = dsn.to_lowercase();
    lower.contains("oracle") || lower.contains("dbq=")
}

/// Run a one-shot SQL statement against `conn_id`, propagating errors
/// via panic with `ctx` for diagnostics. Used to seed scratch tables
/// and INSERTs around an XA branch.
fn oracle_exec(handles: &SharedHandleManager, conn_id: u32, sql: &str, ctx: &str) {
    let conn_arc = {
        let h = handles.lock().expect("handles lock");
        h.get_connection(conn_id).expect("conn lookup")
    };
    let conn = conn_arc.lock().expect("conn lock");
    odbc_engine::engine::execute_query_with_connection(conn.connection(), sql)
        .unwrap_or_else(|e| panic!("{ctx}: {e}"));
}

/// Drop a per-test scratch table; swallows `ORA-00942` so the helper
/// is idempotent across reruns.
fn oracle_drop_table(handles: &SharedHandleManager, conn_id: u32, table: &str) {
    let sql = format!(
        "BEGIN EXECUTE IMMEDIATE 'DROP TABLE {table}'; \
         EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;",
        table = table,
    );
    let conn_arc = {
        let h = handles.lock().expect("handles lock");
        h.get_connection(conn_id).expect("conn lookup")
    };
    let conn = conn_arc.lock().expect("conn lock");
    let _ = odbc_engine::engine::execute_query_with_connection(conn.connection(), &sql);
}

/// Run a `SELECT COUNT(*)`-shaped query and return the integer. We
/// scan the wire bytes for the first ASCII digit run rather than
/// re-implementing the protocol decoder — adequate for the
/// single-int answers we ask of Oracle here.
fn oracle_count(handles: &SharedHandleManager, conn_id: u32, sql: &str) -> i64 {
    let conn_arc = {
        let h = handles.lock().expect("handles lock");
        h.get_connection(conn_id).expect("conn lookup")
    };
    let conn = conn_arc.lock().expect("conn lock");
    let result = odbc_engine::engine::execute_query_with_connection(conn.connection(), sql)
        .unwrap_or_else(|e| panic!("count query failed: {e}"));
    let s = String::from_utf8_lossy(&result);
    for chunk in s.split(|c: char| !c.is_ascii_digit()) {
        if let Ok(n) = chunk.parse::<i64>() {
            return n;
        }
    }
    panic!("could not parse integer from query result: {s:?}");
}

#[test]
fn test_e2e_xa_oracle_full_2pc_commit_path() {
    let Some(conn_str) = get_oracle_test_dsn() else {
        eprintln!("[SKIP] Oracle DSN not configured");
        return;
    };
    if !dsn_targets_oracle(&conn_str) {
        eprintln!("[SKIP] DSN does not target Oracle: {conn_str}");
        return;
    }

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let Some(conn) = try_connect(&env, &conn_str, "Oracle") else {
        return;
    };
    let conn_id = conn.get_connection_id();

    oracle_drop_table(&handles, conn_id, "ora_xa_2pc_scratch");
    oracle_exec(
        &handles,
        conn_id,
        "CREATE TABLE ora_xa_2pc_scratch (k VARCHAR2(64) PRIMARY KEY)",
        "create scratch table",
    );

    let xid = unique_xid("ora-2pc-commit");
    let xa = XaTransaction::start(handles.clone(), conn_id, xid.clone())
        .expect("xa_start (Oracle: DBMS_XA.XA_START)");

    // INSERT inside the XA branch so PREPARE actually writes a log
    // record (without DML Oracle returns XA_RDONLY and the prepared
    // entry never appears in DBA_PENDING_TRANSACTIONS).
    oracle_exec(
        &handles,
        conn_id,
        "INSERT INTO ora_xa_2pc_scratch (k) VALUES ('committed-via-xa')",
        "insert inside XA branch",
    );

    let preparing = xa
        .end()
        .expect("xa_end (Oracle: DBMS_XA.XA_END(TMSUCCESS))");
    let prepared = preparing
        .prepare()
        .expect("xa_prepare (Oracle: DBMS_XA.XA_PREPARE)");

    let recovered = recover_prepared_xids(handles.clone(), conn_id)
        .expect("xa_recover must succeed (DBA_PENDING_TRANSACTIONS)");
    assert!(
        recovered.iter().any(|x| x == &xid),
        "xid must appear in DBA_PENDING_TRANSACTIONS after PREPARE; recovered: {:?}",
        recovered,
    );

    prepared
        .commit()
        .expect("xa_commit_prepared (Oracle: DBMS_XA.XA_COMMIT(FALSE))");

    let after = recover_prepared_xids(handles.clone(), conn_id).expect("post-commit recover");
    assert!(
        !after.iter().any(|x| x == &xid),
        "xid must NOT appear in DBA_PENDING_TRANSACTIONS after COMMIT",
    );

    let n = oracle_count(
        &handles,
        conn_id,
        "SELECT COUNT(*) FROM ora_xa_2pc_scratch WHERE k = 'committed-via-xa'",
    );
    assert_eq!(n, 1, "row inserted via XA must survive 2PC commit");

    oracle_drop_table(&handles, conn_id, "ora_xa_2pc_scratch");
    println!("OK Oracle full 2PC commit lifecycle round-trip via DBMS_XA");
    conn.disconnect().expect("disconnect");
}

#[test]
fn test_e2e_xa_oracle_rollback_prepared_path() {
    let Some(conn_str) = get_oracle_test_dsn() else {
        eprintln!("[SKIP] Oracle DSN not configured");
        return;
    };
    if !dsn_targets_oracle(&conn_str) {
        eprintln!("[SKIP] DSN does not target Oracle: {conn_str}");
        return;
    }

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let Some(conn) = try_connect(&env, &conn_str, "Oracle") else {
        return;
    };
    let conn_id = conn.get_connection_id();

    oracle_drop_table(&handles, conn_id, "ora_xa_rb_scratch");
    oracle_exec(
        &handles,
        conn_id,
        "CREATE TABLE ora_xa_rb_scratch (k VARCHAR2(64) PRIMARY KEY)",
        "create scratch table",
    );

    let xid = unique_xid("ora-2pc-rollback");
    let xa = XaTransaction::start(handles.clone(), conn_id, xid.clone()).expect("xa_start");
    oracle_exec(
        &handles,
        conn_id,
        "INSERT INTO ora_xa_rb_scratch (k) VALUES ('should-rollback')",
        "insert inside XA branch",
    );

    let preparing = xa.end().expect("xa_end");
    let prepared = preparing.prepare().expect("xa_prepare");
    prepared.rollback().expect("xa_rollback_prepared");

    let after = recover_prepared_xids(handles.clone(), conn_id).expect("post-rollback recover");
    assert!(
        !after.iter().any(|x| x == &xid),
        "xid must be gone after ROLLBACK PREPARED",
    );

    let n = oracle_count(
        &handles,
        conn_id,
        "SELECT COUNT(*) FROM ora_xa_rb_scratch WHERE k = 'should-rollback'",
    );
    assert_eq!(n, 0, "rolled-back row must not survive");

    oracle_drop_table(&handles, conn_id, "ora_xa_rb_scratch");
    println!("OK Oracle ROLLBACK PREPARED clears DBA_PENDING_TRANSACTIONS");
    conn.disconnect().expect("disconnect");
}

#[test]
fn test_e2e_xa_oracle_one_phase_commit_shortcut() {
    let Some(conn_str) = get_oracle_test_dsn() else {
        eprintln!("[SKIP] Oracle DSN not configured");
        return;
    };
    if !dsn_targets_oracle(&conn_str) {
        eprintln!("[SKIP] DSN does not target Oracle: {conn_str}");
        return;
    }

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();
    let Some(conn) = try_connect(&env, &conn_str, "Oracle") else {
        return;
    };
    let conn_id = conn.get_connection_id();

    let xid = unique_xid("ora-1rm-commit");
    let xa = XaTransaction::start(handles.clone(), conn_id, xid.clone()).expect("xa_start");

    // 1RM: TMONEPHASE collapses prepare+commit. With no DML the
    // branch is read-only and TMONEPHASE still succeeds (Oracle
    // treats it as a no-op fast path).
    xa.commit_one_phase()
        .expect("commit_one_phase (Oracle: DBMS_XA.XA_COMMIT(TRUE))");

    let after = recover_prepared_xids(handles, conn_id).expect("recover");
    assert!(
        !after.iter().any(|x| x == &xid),
        "1RM commit must NOT leave a prepared entry on Oracle",
    );

    println!("OK Oracle commit_one_phase emits DBMS_XA.XA_COMMIT(TRUE)");
    conn.disconnect().expect("disconnect");
}

#[test]
fn test_e2e_xa_oracle_resume_prepared_after_disconnect() {
    let Some(conn_str) = get_oracle_test_dsn() else {
        eprintln!("[SKIP] Oracle DSN not configured");
        return;
    };
    if !dsn_targets_oracle(&conn_str) {
        eprintln!("[SKIP] DSN does not target Oracle: {conn_str}");
        return;
    }

    let env = OdbcEnvironment::new();
    env.init().expect("init");
    let handles = env.get_handles();

    let Some(conn1) = try_connect(&env, &conn_str, "Oracle") else {
        return;
    };

    let xid = {
        let conn = conn1;
        let conn_id = conn.get_connection_id();

        oracle_drop_table(&handles, conn_id, "ora_xa_resume_scratch");
        oracle_exec(
            &handles,
            conn_id,
            "CREATE TABLE ora_xa_resume_scratch (k VARCHAR2(64) PRIMARY KEY)",
            "create scratch",
        );

        let xid = unique_xid("ora-resume");
        let xa = XaTransaction::start(handles.clone(), conn_id, xid.clone()).expect("xa_start");
        oracle_exec(
            &handles,
            conn_id,
            "INSERT INTO ora_xa_resume_scratch (k) VALUES ('survives-disconnect')",
            "insert inside branch",
        );
        let preparing = xa.end().expect("xa_end");
        let _prepared = preparing.prepare().expect("xa_prepare");
        // Drop _prepared without committing — Oracle's prepare log
        // outlives the session.
        conn.disconnect().expect("disconnect 1");
        xid
    };

    let Some(conn) = try_connect(&env, &conn_str, "Oracle") else {
        return;
    };
    let conn_id = conn.get_connection_id();

    let recovered =
        recover_prepared_xids(handles.clone(), conn_id).expect("recover on a fresh connection");
    assert!(
        recovered.iter().any(|x| x == &xid),
        "xid prepared on connection 1 must show up on connection 2; recovered: {:?}",
        recovered,
    );

    let prepared = resume_prepared(handles.clone(), conn_id, xid.clone())
        .expect("resume_prepared rebuilds the handle");
    prepared.commit().expect("commit after recovery");

    let after = recover_prepared_xids(handles.clone(), conn_id).expect("post-commit recover");
    assert!(
        !after.iter().any(|x| x == &xid),
        "xid must be gone after recovery commit",
    );

    oracle_drop_table(&handles, conn_id, "ora_xa_resume_scratch");
    println!("OK Oracle prepared XID survives disconnect and is recoverable");
    conn.disconnect().expect("disconnect 2");
}

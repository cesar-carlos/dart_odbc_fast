//! Opt-in E2E: Oracle DRT1 + `ParamValue::RefCursorOut` (materialized `RC1\0`).
//!
//! The Oracle Database ODBC model omits `?` for ref-cursor parameters in the
//! call text; result sets are read via `SQLMoreResults` in procedure order. See
//! `engine::core::ref_cursor_oracle` and `doc/notes/REF_CURSOR_ORACLE_ROADMAP.md`.
//!
//! **Run (host with Oracle + Instant Client ODBC):**
//! `E2E_ORACLE_REFCURSOR=1` and `ODBC_TEST_DSN` (or `ORACLE_TEST_*` from
//! `helpers::env`); `cargo test e2e_oracle_ref_cursor_smoke -- --ignored`.

mod helpers;

use helpers::env::get_oracle_test_dsn;
use odbc_engine::engine::core::ExecutionEngine;
use odbc_engine::protocol::bound_param::{BoundParam, ParamDirection};
use odbc_engine::{OdbcConnection, OdbcEnvironment, ParamValue};

const RC1: [u8; 4] = [b'R', b'C', b'1', 0];
// Same 4 LE bytes as `RowBuffer` / `RowBufferEncoder` (see `protocol/encoder.rs`)
const V1: u32 = 0x4F44_4243;

fn dsn_looks_oracle(s: &str) -> bool {
    let l = s.to_lowercase();
    l.contains("oracle")
        || l.contains("dbq=")
        || l.contains("orcl")
        || l.contains("service name")
        || l.contains("service_name")
}

/// Creates a small package, runs one directed call, then drops the package.
#[test]
#[ignore]
fn e2e_oracle_ref_cursor_smoke() {
    if std::env::var("E2E_ORACLE_REFCURSOR")
        .map(|s| s == "1" || s.eq_ignore_ascii_case("true"))
        .ok()
        != Some(true)
    {
        eprintln!("⚠️  set E2E_ORACLE_REFCURSOR=1 to run (requires Oracle DSN + privileges)");
        return;
    }
    let Some(dsn) = get_oracle_test_dsn() else {
        eprintln!("⚠️  No Oracle DSN (ODBC_TEST_DSN or ORACLE_TEST_*)");
        return;
    };
    if !dsn_looks_oracle(&dsn) {
        eprintln!("⚠️  DSN does not look like Oracle: {dsn}");
        return;
    }

    let env = OdbcEnvironment::new();
    env.init().expect("OdbcEnvironment::init");
    let conn = OdbcConnection::connect(env.get_handles(), &dsn).expect("connect");
    let handles = conn.get_handles();
    let guard = handles.lock().unwrap();
    let arc = guard
        .get_connection(conn.get_connection_id())
        .expect("get_connection");
    let odbc = arc.lock().unwrap();
    let engine = ExecutionEngine::new(4);
    engine.set_connection_string(&dsn);

    let spec = "CREATE OR REPLACE PACKAGE ODBC_E2E_RC AS\n\
PROCEDURE p(c1 IN OUT SYS_REFCURSOR, c2 IN OUT SYS_REFCURSOR, pjob IN VARCHAR2);\n\
END;\n";
    if engine.execute_query(&odbc, spec).is_err() {
        eprintln!("⚠️  could not create package spec (check privileges)");
        return;
    }
    let body = "CREATE OR REPLACE PACKAGE BODY ODBC_E2E_RC AS\n\
PROCEDURE p(c1 IN OUT SYS_REFCURSOR, c2 IN OUT SYS_REFCURSOR, pjob IN VARCHAR2) AS\n\
BEGIN\n\
  OPEN c1 FOR SELECT 1 AS x FROM dual;\n\
  OPEN c2 FOR SELECT 2 AS y FROM dual;\n\
END p;\n\
END ODBC_E2E_RC;\n";
    if engine.execute_query(&odbc, body).is_err() {
        eprintln!("⚠️  could not create package body");
        let _ = engine.execute_query(&odbc, "DROP PACKAGE ODBC_E2E_RC");
        return;
    }

    let bound = [
        BoundParam {
            direction: ParamDirection::InOut,
            value: ParamValue::RefCursorOut,
        },
        BoundParam {
            direction: ParamDirection::InOut,
            value: ParamValue::RefCursorOut,
        },
        BoundParam {
            direction: ParamDirection::Input,
            value: ParamValue::String("SALES".into()),
        },
    ];
    let sql = "{ CALL ODBC_E2E_RC.p(?,?,?) }";
    let buf =
        match engine.execute_query_with_bound_params_and_timeout(&odbc, sql, &bound, None, None) {
            Ok(b) => b,
            Err(e) => {
                eprintln!("⚠️  execute directed failed: {e}");
                let _ = engine.execute_query(&odbc, "DROP PACKAGE ODBC_E2E_RC");
                return;
            }
        };

    assert!(
        buf.windows(4).any(|w| w == RC1),
        "expected RC1\\0 trailer, len={} prefix={:02x?}",
        buf.len(),
        buf.get(..32.min(buf.len()))
    );
    // Empty main (v1) + two cursors in RC1 each have the ODDB magic.
    let mut odbc_v1 = 0usize;
    for i in 0..buf.len().saturating_sub(3) {
        if u32::from_le_bytes(buf[i..i + 4].try_into().unwrap()) == V1 {
            odbc_v1 += 1;
        }
    }
    assert!(
        odbc_v1 >= 2,
        "expected v1 message(s) in buffer, got {odbc_v1}"
    );

    let _ = engine.execute_query(&odbc, "DROP PACKAGE ODBC_E2E_RC");
    drop(odbc);
    drop(guard);
    conn.disconnect().ok();
}

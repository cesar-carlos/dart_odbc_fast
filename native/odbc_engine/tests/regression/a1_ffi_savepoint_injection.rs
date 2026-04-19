//! A1 (B1 v3.1) — Savepoint identifier injection MUST be rejected at the FFI
//! boundary, not just by the high-level `Savepoint::create` helper.
//!
//! Background
//! ----------
//! The pre-v3.1 FFI implementation of `odbc_savepoint_create / _rollback /
//! _release` did:
//!
//! ```ignore
//! txn.execute_sql(&format!("SAVEPOINT {}", name_str))
//! ```
//!
//! That bypassed `validate_identifier` and `quote_identifier`, reintroducing
//! the SQL-injection vector originally fixed by audit finding A1. v3.1 routes
//! every FFI savepoint call through `Transaction::savepoint_create /
//! _rollback_to / _release`, which validate and quote.
//!
//! These tests poke the public Rust surface that the FFI now uses; combined
//! with the unit tests in `transaction.rs`, they ensure the regression cannot
//! re-appear silently. End-to-end coverage with a real DSN is gated by
//! `ODBC_TEST_DSN` and currently lives under
//! `tests/transaction_test.rs::test_savepoint`.

use odbc_engine::engine::{IsolationLevel, SavepointDialect};
use odbc_engine::OdbcError;

/// Identifier strings every FFI savepoint entry point MUST reject.
const MALICIOUS_NAMES: &[&str] = &[
    "sp; DROP TABLE users--",
    "sp\";DROP TABLE x;--",
    "sp' OR '1'='1",
    "sp/* comment */",
    "sp UNION SELECT 1",
    "",
    "1leading_digit",
    "sp space",
    "sp.dotted",
    "sp[bracket]",
    "sp\"quote",
];

#[test]
fn transaction_savepoint_create_rejects_injection_on_sql92() {
    let txn = test_only_txn(SavepointDialect::Sql92);
    for bad in MALICIOUS_NAMES {
        let r = txn.savepoint_create(bad);
        assert!(
            matches!(r, Err(OdbcError::ValidationError(_))),
            "savepoint_create must reject {bad:?} on Sql92, got {r:?}"
        );
    }
}

#[test]
fn transaction_savepoint_create_rejects_injection_on_sqlserver() {
    let txn = test_only_txn(SavepointDialect::SqlServer);
    for bad in MALICIOUS_NAMES {
        let r = txn.savepoint_create(bad);
        assert!(
            matches!(r, Err(OdbcError::ValidationError(_))),
            "savepoint_create must reject {bad:?} on SqlServer, got {r:?}"
        );
    }
}

#[test]
fn transaction_savepoint_rollback_to_rejects_injection() {
    let txn = test_only_txn(SavepointDialect::Sql92);
    for bad in MALICIOUS_NAMES {
        let r = txn.savepoint_rollback_to(bad);
        assert!(
            matches!(r, Err(OdbcError::ValidationError(_))),
            "savepoint_rollback_to must reject {bad:?}, got {r:?}"
        );
    }
}

#[test]
fn transaction_savepoint_release_rejects_injection_on_both_dialects() {
    for dialect in [SavepointDialect::Sql92, SavepointDialect::SqlServer] {
        let txn = test_only_txn(dialect);
        for bad in MALICIOUS_NAMES {
            let r = txn.savepoint_release(bad);
            assert!(
                matches!(r, Err(OdbcError::ValidationError(_))),
                "savepoint_release must reject {bad:?} on {dialect:?}, got {r:?}"
            );
        }
    }
}

#[test]
fn transaction_savepoint_create_accepts_valid_names_then_fails_on_missing_conn() {
    // Valid identifiers pass validation and only THEN attempt to talk to the
    // (bogus) connection. The error must therefore not be ValidationError.
    let txn = test_only_txn(SavepointDialect::Sql92);
    for good in ["sp1", "sp_outer", "_a", "MixedCase42"] {
        let r = txn.savepoint_create(good);
        assert!(
            !matches!(r, Err(OdbcError::ValidationError(_))),
            "valid identifier {good:?} must not trigger ValidationError: got {r:?}"
        );
    }
}

#[test]
fn savepoint_dialect_default_is_auto_in_v3_1() {
    // v3.1 changed the FFI default from Sql92 (legacy) to Auto so that callers
    // who never pass an explicit dialect still get the right SQL on SQL Server.
    assert_eq!(SavepointDialect::from_u32(0), SavepointDialect::Auto);
    assert_eq!(SavepointDialect::from_u32(1), SavepointDialect::SqlServer);
    assert_eq!(SavepointDialect::from_u32(2), SavepointDialect::Sql92);
}

// -- helpers --------------------------------------------------------------

fn test_only_txn(dialect: SavepointDialect) -> odbc_engine::engine::Transaction {
    use odbc_engine::engine::TransactionState;
    odbc_engine::engine::Transaction::for_test_no_conn(
        TransactionState::Active,
        IsolationLevel::ReadCommitted,
        dialect,
    )
}

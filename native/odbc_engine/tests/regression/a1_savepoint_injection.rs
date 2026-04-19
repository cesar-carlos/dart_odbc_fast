//! A1 — Savepoint names must be quoted/validated before interpolation in SQL.

use odbc_engine::engine::quote_identifier_default;

#[test]
fn quote_identifier_accepts_simple_names() {
    assert_eq!(
        quote_identifier_default("sp1").expect("simple name should pass"),
        "\"sp1\"".to_string()
    );
}

#[test]
fn quote_identifier_rejects_injection_attempts() {
    let bad = ["sp; DROP TABLE users--", "sp\"; DELETE FROM x;--", ""];
    for n in bad {
        assert!(
            quote_identifier_default(n).is_err(),
            "name {n:?} must be rejected"
        );
    }
}

#[test]
fn quote_identifier_rejects_overly_long_names() {
    let long_name = "a".repeat(200);
    assert!(quote_identifier_default(&long_name).is_err());
}

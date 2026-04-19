//! A2 — Table/column identifiers in `ArrayBinding` (and other dynamically built SQL)
//! must be validated and quoted using `quote_identifier_default`.

use odbc_engine::engine::quote_identifier_default;

#[test]
fn quote_identifier_rejects_table_with_semicolon() {
    let r = quote_identifier_default("users; DROP TABLE x");
    assert!(r.is_err());
}

#[test]
fn quote_identifier_rejects_table_with_quotes() {
    let r = quote_identifier_default("users\"; --");
    assert!(r.is_err());
}

#[test]
fn quote_identifier_accepts_underscored_name() {
    let r = quote_identifier_default("user_table_2");
    assert_eq!(r.expect("valid name"), "\"user_table_2\"");
}

#[test]
fn quote_identifier_rejects_empty_name() {
    assert!(quote_identifier_default("").is_err());
}

#[test]
fn quote_identifier_rejects_name_starting_with_digit() {
    assert!(quote_identifier_default("1users").is_err());
}

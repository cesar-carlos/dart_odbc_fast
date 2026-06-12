//! Malicious and boundary inputs for catalog table reference parsing.
//!
//! `parse_catalog_table_ref` splits `schema.table`, then validates each segment
//! with [`validate_identifier`] (ASCII alnum + underscore, max 128 chars).

use odbc_engine::engine::parse_catalog_table_ref;
use odbc_engine::OdbcError;

fn assert_validation_err(table: &str) {
    let err = parse_catalog_table_ref(table).expect_err("expected validation error");
    assert!(
        matches!(err, OdbcError::ValidationError(_)),
        "expected ValidationError for {table:?}, got {err:?}"
    );
}

#[test]
fn should_reject_empty_and_whitespace_only_table_refs() {
    assert_validation_err("");
    assert_validation_err("   ");
    assert_validation_err("\t\n");
}

#[test]
fn should_reject_blank_segment_after_schema_dot() {
    assert_validation_err("dbo.");
    assert_validation_err("dbo.   ");
    assert_validation_err("schema.\t");
}

#[test]
fn should_reject_sql_injection_like_table_names() {
    assert_validation_err("dbo.table'; DROP TABLE users; --");
    assert_validation_err("'; DELETE FROM users; --");
}

#[test]
fn should_reject_semicolon_and_quote_payloads() {
    assert_validation_err("a;b'c.d");
    assert_validation_err("dbo.\"evil\"");
}

#[test]
fn should_reject_embedded_null_byte_in_table_segment() {
    assert_validation_err("dbo.table\u{0000}suffix");
}

#[test]
fn should_reject_unicode_identifiers() {
    assert_validation_err("dbo.Usuários");
}

#[test]
fn should_reject_very_long_table_ref() {
    let long = "x".repeat(129);
    assert_validation_err(&format!("dbo.{long}"));
}

#[test]
fn should_accept_long_table_ref_at_identifier_limit() {
    let long = "x".repeat(128);
    let (schema, name) = parse_catalog_table_ref(&format!("dbo.{long}")).expect("at limit");
    assert_eq!(schema.as_deref(), Some("dbo"));
    assert_eq!(name, long);
}

#[test]
fn should_use_last_dot_as_schema_separator_for_valid_segments() {
    let (schema, name) = parse_catalog_table_ref("sales.orders.items").expect("multi segment");
    assert_eq!(schema.as_deref(), Some("sales.orders"));
    assert_eq!(name, "items");
}

#[test]
fn should_reject_single_dot_only_table_ref() {
    assert_validation_err(".");
}

#[test]
fn should_trim_surrounding_whitespace_on_valid_segments() {
    let (schema, name) = parse_catalog_table_ref("  sales  .  orders  ").expect("trimmed");
    assert_eq!(schema.as_deref(), Some("sales"));
    assert_eq!(name, "orders");
}

#[test]
fn should_reject_path_traversal_like_table_name() {
    assert_validation_err("../../../etc/passwd");
}

#[test]
fn should_accept_ascii_underscore_table_names() {
    let (schema, name) = parse_catalog_table_ref("dbo.Users_Table1").expect("valid ascii");
    assert_eq!(schema.as_deref(), Some("dbo"));
    assert_eq!(name, "Users_Table1");
}

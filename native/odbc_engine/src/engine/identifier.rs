//! SQL identifier validation and quoting helpers.
//!
//! Used by `Transaction`/`Savepoint`, `ArrayBinding` and any code that builds
//! dynamic SQL with caller-supplied identifiers (table/column/savepoint names).
//!
//! Replaces ad-hoc `format!("{ident}")` interpolation that exposed SQL
//! injection vectors (audit findings A1, A2).

use crate::error::{OdbcError, Result};

/// Maximum identifier length accepted by [`validate_identifier`].
///
/// Conservative cap chosen as the minimum across major DBs:
/// - SQL Server: 128
/// - PostgreSQL: 63 (but accepts more with quoting)
/// - MySQL: 64
/// - Oracle: 30 (legacy) / 128 (12.2+)
/// - Sybase: 128
pub const MAX_IDENTIFIER_LEN: usize = 128;

/// Vendor-specific identifier quoting style.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdentifierQuoting {
    /// `"name"` — SQL-92 default (PostgreSQL, Oracle, DB2, ANSI mode).
    DoubleQuote,
    /// `[name]` — SQL Server / Sybase ASA / Access.
    Brackets,
    /// `` `name` `` — MySQL / MariaDB.
    Backtick,
}

impl IdentifierQuoting {
    /// Wrap an already-validated identifier in quoting characters.
    /// Caller MUST have validated the input via [`validate_identifier`] first.
    pub(crate) fn wrap(self, validated: &str) -> String {
        match self {
            IdentifierQuoting::DoubleQuote => format!("\"{validated}\""),
            IdentifierQuoting::Brackets => format!("[{validated}]"),
            IdentifierQuoting::Backtick => format!("`{validated}`"),
        }
    }
}

/// Validate that `name` is safe to interpolate as an SQL identifier.
///
/// Accepts: ASCII letter or `_` followed by up to [`MAX_IDENTIFIER_LEN`]-1
/// ASCII letters, digits or `_`.
///
/// Rejects everything else (semicolons, quotes, comments, dots, brackets,
/// whitespace, non-ASCII, empty, leading digit, etc.) with
/// [`OdbcError::ValidationError`].
pub fn validate_identifier(name: &str) -> Result<()> {
    if name.is_empty() {
        return Err(OdbcError::ValidationError(
            "Identifier must not be empty".to_string(),
        ));
    }
    if name.len() > MAX_IDENTIFIER_LEN {
        return Err(OdbcError::ValidationError(format!(
            "Identifier exceeds {MAX_IDENTIFIER_LEN} characters"
        )));
    }
    let bytes = name.as_bytes();
    let first = bytes[0];
    let first_ok = first.is_ascii_alphabetic() || first == b'_';
    if !first_ok {
        return Err(OdbcError::ValidationError(format!(
            "Identifier {name:?} must start with ASCII letter or underscore"
        )));
    }
    for &b in &bytes[1..] {
        let ok = b.is_ascii_alphanumeric() || b == b'_';
        if !ok {
            return Err(OdbcError::ValidationError(format!(
                "Identifier {name:?} contains invalid character {:?}",
                b as char
            )));
        }
    }
    Ok(())
}

/// Validate `name` and return it wrapped using the given quoting style.
pub fn quote_identifier(name: &str, style: IdentifierQuoting) -> Result<String> {
    validate_identifier(name)?;
    Ok(style.wrap(name))
}

/// Convenience: validate and quote with the SQL-92 default (`"name"`).
///
/// Use this for engines that accept double-quoted identifiers (PostgreSQL,
/// Oracle, ANSI mode of MySQL/SQL Server). For SQL Server with bracket
/// quoting use [`quote_identifier`] with [`IdentifierQuoting::Brackets`].
pub fn quote_identifier_default(name: &str) -> Result<String> {
    quote_identifier(name, IdentifierQuoting::DoubleQuote)
}

/// Validate and quote a possibly-qualified identifier (`schema.table`).
///
/// Each segment is validated independently; the result is `"schema"."table"`.
/// Useful for INSERT/SELECT against schema-qualified tables.
pub fn quote_qualified_default(qualified: &str) -> Result<String> {
    let parts: Vec<&str> = qualified.split('.').collect();
    if parts.is_empty() {
        return Err(OdbcError::ValidationError(
            "Qualified identifier must not be empty".to_string(),
        ));
    }
    let mut quoted_parts = Vec::with_capacity(parts.len());
    for p in parts {
        quoted_parts.push(quote_identifier_default(p)?);
    }
    Ok(quoted_parts.join("."))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_identifier_accepts_simple_names() {
        assert!(validate_identifier("a").is_ok());
        assert!(validate_identifier("table_1").is_ok());
        assert!(validate_identifier("_underscore").is_ok());
        assert!(validate_identifier("Mixed_Case_2").is_ok());
    }

    #[test]
    fn validate_identifier_rejects_empty() {
        assert!(validate_identifier("").is_err());
    }

    #[test]
    fn validate_identifier_rejects_leading_digit() {
        assert!(validate_identifier("1table").is_err());
    }

    #[test]
    fn validate_identifier_rejects_special_characters() {
        for bad in [
            "tab le", "tab;le", "tab\"le", "tab'le", "tab--le", "tab/*", "tab.le", "tab(le",
            "tab)le", "tab[le", "tab]le", "tab\nle",
        ] {
            assert!(validate_identifier(bad).is_err(), "should reject {bad:?}");
        }
    }

    #[test]
    fn validate_identifier_rejects_non_ascii() {
        assert!(validate_identifier("naïve").is_err());
        assert!(validate_identifier("日本語").is_err());
    }

    #[test]
    fn validate_identifier_rejects_overlong() {
        let too_long = "a".repeat(MAX_IDENTIFIER_LEN + 1);
        assert!(validate_identifier(&too_long).is_err());
    }

    #[test]
    fn validate_identifier_accepts_max_length() {
        let exact = "a".repeat(MAX_IDENTIFIER_LEN);
        assert!(validate_identifier(&exact).is_ok());
    }

    #[test]
    fn quote_default_wraps_in_double_quotes() {
        assert_eq!(quote_identifier_default("users").unwrap(), "\"users\"");
    }

    #[test]
    fn quote_brackets_wraps_in_square_brackets() {
        assert_eq!(
            quote_identifier("users", IdentifierQuoting::Brackets).unwrap(),
            "[users]"
        );
    }

    #[test]
    fn quote_backtick_wraps_in_backticks() {
        assert_eq!(
            quote_identifier("users", IdentifierQuoting::Backtick).unwrap(),
            "`users`"
        );
    }

    #[test]
    fn quote_qualified_handles_schema_dot_table() {
        assert_eq!(
            quote_qualified_default("public.users").unwrap(),
            "\"public\".\"users\""
        );
    }

    #[test]
    fn quote_qualified_rejects_injection_in_any_segment() {
        assert!(quote_qualified_default("public.users; DROP TABLE x").is_err());
        assert!(quote_qualified_default("public.").is_err());
        assert!(quote_qualified_default(".users").is_err());
    }

    #[test]
    fn quote_qualified_handles_three_part_names() {
        assert_eq!(
            quote_qualified_default("db.schema.table").unwrap(),
            "\"db\".\"schema\".\"table\""
        );
    }

    #[test]
    fn quote_default_rejects_classic_injection_attempts() {
        for bad in [
            "table; DROP TABLE users--",
            "table\";DROP TABLE x;--",
            "table' OR '1'='1",
            "'; DELETE FROM x;--",
        ] {
            assert!(
                quote_identifier_default(bad).is_err(),
                "must reject injection attempt {bad:?}"
            );
        }
    }
}

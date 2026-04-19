//! RETURNING / OUTPUT capability.
//!
//! Generates dialect-specific clauses for `INSERT`/`UPDATE`/`DELETE` so the
//! caller can fetch server-side computed columns (autoincrement keys,
//! defaults, computed columns) in a **single round trip**.

use crate::engine::identifier::{quote_identifier_default, validate_identifier};
use crate::error::{OdbcError, Result};

/// Statement category that may be combined with a RETURNING/OUTPUT clause.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DmlVerb {
    Insert,
    Update,
    Delete,
}

/// Capability trait for engines that expose RETURNING / OUTPUT clauses.
pub trait Returnable: Send + Sync {
    /// True when the engine supports RETURNING-style clauses at all.
    fn supports_returning(&self) -> bool {
        true
    }

    /// True when the clause produces a forward result set the caller can
    /// `SQLFetch` (PG/MariaDB/SQLite/SQL Server). False when results are
    /// delivered through OUT bind variables (Oracle).
    fn returns_resultset(&self) -> bool {
        true
    }

    /// Append (or insert) the RETURNING clause to a DML statement.
    ///
    /// `sql` is the original DML; `verb` describes its category (matters for
    /// SQL Server, where OUTPUT placement differs between INSERT/UPDATE/DELETE);
    /// `columns` are the unquoted server-side identifiers to project.
    fn append_returning_clause(&self, sql: &str, verb: DmlVerb, columns: &[&str])
        -> Result<String>;
}

/// Helper: validate every column name and return them quoted, comma-joined.
pub fn quote_returning_columns(columns: &[&str]) -> Result<String> {
    if columns.is_empty() {
        return Err(OdbcError::ValidationError(
            "RETURNING requires at least one column".to_string(),
        ));
    }
    let mut out = Vec::with_capacity(columns.len());
    for c in columns {
        validate_identifier(c)?;
        out.push(quote_identifier_default(c)?);
    }
    Ok(out.join(", "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quote_returning_rejects_empty() {
        assert!(quote_returning_columns(&[]).is_err());
    }

    #[test]
    fn quote_returning_quotes_valid() {
        let q = quote_returning_columns(&["id", "created_at"]).unwrap();
        assert_eq!(q, "\"id\", \"created_at\"");
    }

    #[test]
    fn quote_returning_rejects_injection() {
        assert!(quote_returning_columns(&["id; DROP TABLE t"]).is_err());
    }

    #[test]
    fn dml_verb_variants_distinct() {
        assert_ne!(DmlVerb::Insert, DmlVerb::Update);
        assert_ne!(DmlVerb::Update, DmlVerb::Delete);
    }
}

//! UPSERT (INSERT-OR-UPDATE) capability per-driver.
//!
//! Generates dialect-specific SQL such that the caller can keep using
//! standard prepared-statement execution. Identifiers are validated and
//! quoted via [`crate::engine::identifier`] to avoid injection.

use crate::engine::identifier::{quote_identifier_default, validate_identifier};
use crate::error::{OdbcError, Result};

/// Capability trait for engines that expose a single-statement UPSERT.
///
/// Implementations must:
/// - validate every identifier (table, columns, conflict columns) and reject
///   anything that would not pass [`validate_identifier`];
/// - return SQL with `?` placeholders for each value column, in the order
///   given by `columns`;
/// - never re-quote already-quoted identifiers (the helpers below accept raw
///   names and quote internally).
pub trait Upsertable: Send + Sync {
    /// Build an UPSERT for `table` with values for `columns`. On conflict over
    /// `conflict_columns` the engine updates either `update_columns` (when
    /// `Some`) or every non-conflict column (when `None`).
    fn build_upsert_sql(
        &self,
        table: &str,
        columns: &[&str],
        conflict_columns: &[&str],
        update_columns: Option<&[&str]>,
    ) -> Result<String>;
}

/// Validate and quote a list of identifiers. Returns the comma-joined,
/// quoted result ready to interpolate inside `(...)`.
pub fn quote_columns(columns: &[&str]) -> Result<String> {
    if columns.is_empty() {
        return Err(OdbcError::ValidationError(
            "Upsert requires at least one column".to_string(),
        ));
    }
    let mut out = Vec::with_capacity(columns.len());
    for c in columns {
        out.push(quote_identifier_default(c)?);
    }
    Ok(out.join(", "))
}

/// Computed `update_columns` defaulting to every column not in `conflict_columns`.
pub fn effective_update_columns<'a>(
    columns: &'a [&'a str],
    conflict_columns: &[&str],
    update_columns: Option<&'a [&'a str]>,
) -> Vec<&'a str> {
    if let Some(explicit) = update_columns {
        return explicit.to_vec();
    }
    columns
        .iter()
        .copied()
        .filter(|c| !conflict_columns.contains(c))
        .collect()
}

/// Validate every identifier referenced by an upsert request.
pub fn validate_upsert_inputs(
    table: &str,
    columns: &[&str],
    conflict_columns: &[&str],
    update_columns: Option<&[&str]>,
) -> Result<()> {
    if table.trim().is_empty() {
        return Err(OdbcError::ValidationError(
            "Upsert table must not be empty".to_string(),
        ));
    }
    // Allow schema-qualified table; validate each segment.
    for segment in table.split('.') {
        validate_identifier(segment)?;
    }
    if columns.is_empty() {
        return Err(OdbcError::ValidationError(
            "Upsert requires at least one column".to_string(),
        ));
    }
    if conflict_columns.is_empty() {
        return Err(OdbcError::ValidationError(
            "Upsert requires at least one conflict column".to_string(),
        ));
    }
    for c in columns.iter().chain(conflict_columns.iter()) {
        validate_identifier(c)?;
    }
    if let Some(update) = update_columns {
        for c in update {
            validate_identifier(c)?;
        }
    }
    for cc in conflict_columns {
        if !columns.contains(cc) {
            return Err(OdbcError::ValidationError(format!(
                "Conflict column {cc:?} must also appear in `columns`"
            )));
        }
    }
    Ok(())
}

/// `?, ?, ?` placeholder string for `n` values.
pub fn placeholder_list(n: usize) -> String {
    std::iter::repeat_n("?", n).collect::<Vec<_>>().join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quote_columns_rejects_empty_and_quotes_valid() {
        assert!(quote_columns(&[]).is_err());
        let q = quote_columns(&["id", "name"]).unwrap();
        assert_eq!(q, "\"id\", \"name\"");
    }

    #[test]
    fn quote_columns_rejects_injection() {
        assert!(quote_columns(&["id; DROP TABLE x"]).is_err());
    }

    #[test]
    fn effective_update_columns_defaults_to_non_conflict() {
        let cols = ["id", "a", "b"];
        let conflict = ["id"];
        let r = effective_update_columns(&cols, &conflict, None);
        assert_eq!(r, vec!["a", "b"]);
    }

    #[test]
    fn effective_update_columns_uses_explicit_when_provided() {
        let cols = ["id", "a", "b"];
        let conflict = ["id"];
        let explicit = ["a"];
        let r = effective_update_columns(&cols, &conflict, Some(&explicit));
        assert_eq!(r, vec!["a"]);
    }

    #[test]
    fn validate_inputs_rejects_empty_table() {
        let r = validate_upsert_inputs("", &["a"], &["a"], None);
        assert!(matches!(r, Err(OdbcError::ValidationError(_))));
    }

    #[test]
    fn validate_inputs_rejects_conflict_not_in_columns() {
        let r = validate_upsert_inputs("t", &["a", "b"], &["c"], None);
        assert!(matches!(r, Err(OdbcError::ValidationError(_))));
    }

    #[test]
    fn validate_inputs_accepts_schema_qualified_table() {
        let r = validate_upsert_inputs("public.users", &["id", "name"], &["id"], None);
        assert!(r.is_ok());
    }

    #[test]
    fn placeholder_list_emits_correct_count() {
        assert_eq!(placeholder_list(0), "");
        assert_eq!(placeholder_list(1), "?");
        assert_eq!(placeholder_list(3), "?, ?, ?");
    }
}

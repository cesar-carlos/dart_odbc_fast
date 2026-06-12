use crate::engine::identifier::{quote_identifier, validate_identifier, IdentifierQuoting};
use crate::error::Result;

/// Validate every column and return them quoted with `[brackets]`,
/// comma-joined.
pub(super) fn quote_cols_brackets(columns: &[&str]) -> Result<String> {
    let mut out = Vec::with_capacity(columns.len());
    for c in columns {
        out.push(quote_identifier(c, IdentifierQuoting::Brackets)?);
    }
    Ok(out.join(", "))
}

/// Quote a possibly-qualified table name (`db.schema.table`) using brackets.
pub(super) fn quote_table_brackets(table: &str) -> Result<String> {
    let mut parts = Vec::new();
    for seg in table.split('.') {
        validate_identifier(seg)?;
        parts.push(quote_identifier(seg, IdentifierQuoting::Brackets)?);
    }
    Ok(parts.join("."))
}

use crate::engine::identifier::quote_identifier_default;
use crate::error::Result;

/// Validate and quote each `&str` in `columns`, returning a comma-separated
/// list ready to inject into a SQL `INSERT (...)` clause.
///
/// A2 fix: every column identifier passes through `quote_identifier_default`
/// before reaching the wire, eliminating SQL injection vectors.
pub(super) fn quote_column_list(columns: &[&str]) -> Result<String> {
    let mut out = String::with_capacity(columns.len().saturating_mul(8));
    for (idx, c) in columns.iter().enumerate() {
        if idx > 0 {
            out.push_str(", ");
        }
        out.push_str(&quote_identifier_default(c)?);
    }
    Ok(out)
}

pub(super) fn placeholders(n_cols: usize) -> String {
    let mut out = String::with_capacity(n_cols.saturating_mul(3).saturating_sub(2));
    for idx in 0..n_cols {
        if idx > 0 {
            out.push_str(", ");
        }
        out.push('?');
    }
    out
}

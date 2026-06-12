use super::MySqlPlugin;
use crate::engine::identifier::{quote_identifier, quote_qualified_default, IdentifierQuoting};
use crate::error::{OdbcError, Result};

use super::super::capabilities::upsert::{
    effective_update_columns, placeholder_list, quote_columns, validate_upsert_inputs, Upsertable,
};

impl Upsertable for MySqlPlugin {
    fn build_upsert_sql(
        &self,
        table: &str,
        columns: &[&str],
        conflict_columns: &[&str],
        update_columns: Option<&[&str]>,
    ) -> Result<String> {
        validate_upsert_inputs(table, columns, conflict_columns, update_columns)?;
        let qtable = quote_qualified_default(table)?;
        let qcols = quote_columns(columns)?;
        let updates = effective_update_columns(columns, conflict_columns, update_columns);
        let placeholders = placeholder_list(columns.len());
        if updates.is_empty() {
            return Err(OdbcError::ValidationError(
                "MySQL ON DUPLICATE KEY UPDATE requires at least one column to update".to_string(),
            ));
        }
        let mut set_parts = Vec::with_capacity(updates.len());
        for c in &updates {
            // MySQL idiom: col = VALUES(col) (legacy) — equivalent to col = NEW.col on 8.0+.
            let q = quote_identifier(c, IdentifierQuoting::Backtick)?;
            set_parts.push(format!("{q} = VALUES({q})"));
        }
        let set_clause = set_parts.join(", ");
        Ok(format!(
            "INSERT INTO {qtable} ({qcols}) VALUES ({placeholders}) \
             ON DUPLICATE KEY UPDATE {set_clause}"
        ))
    }
}

use super::MariaDbPlugin;
use crate::engine::identifier::{quote_identifier, quote_qualified_default, IdentifierQuoting};
use crate::error::Result;

use super::super::capabilities::upsert::{
    effective_update_columns, placeholder_list, quote_columns, validate_upsert_inputs, Upsertable,
};

impl Upsertable for MariaDbPlugin {
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

        let set_parts = updates
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier(c, IdentifierQuoting::Backtick)?;
                Ok(format!("{q} = VALUES({q})"))
            })
            .collect::<Result<Vec<_>>>()?;
        let set_clause = if set_parts.is_empty() {
            "id = id".to_string()
        } else {
            set_parts.join(", ")
        };
        Ok(format!(
            "INSERT INTO {qtable} ({qcols}) VALUES ({placeholders}) \
             ON DUPLICATE KEY UPDATE {set_clause}"
        ))
    }
}

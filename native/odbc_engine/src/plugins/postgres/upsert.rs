use super::PostgresPlugin;
use crate::engine::identifier::{quote_identifier_default, quote_qualified_default};
use crate::error::Result;

use super::super::capabilities::upsert::{
    effective_update_columns, placeholder_list, quote_columns, validate_upsert_inputs, Upsertable,
};

impl Upsertable for PostgresPlugin {
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
        let qconflict = quote_columns(conflict_columns)?;
        let updates = effective_update_columns(columns, conflict_columns, update_columns);
        let placeholders = placeholder_list(columns.len());

        // PostgreSQL ON CONFLICT ... DO UPDATE SET col = EXCLUDED.col
        if updates.is_empty() {
            // No columns to update -> degrade to ON CONFLICT DO NOTHING.
            return Ok(format!(
                "INSERT INTO {qtable} ({qcols}) VALUES ({placeholders}) \
                 ON CONFLICT ({qconflict}) DO NOTHING"
            ));
        }
        let mut set_parts = Vec::with_capacity(updates.len());
        for c in &updates {
            let q = quote_identifier_default(c)?;
            set_parts.push(format!("{q} = EXCLUDED.{q}"));
        }
        let set_clause = set_parts.join(", ");
        Ok(format!(
            "INSERT INTO {qtable} ({qcols}) VALUES ({placeholders}) \
             ON CONFLICT ({qconflict}) DO UPDATE SET {set_clause}"
        ))
    }
}

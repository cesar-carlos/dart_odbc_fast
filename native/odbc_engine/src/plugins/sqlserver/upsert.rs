use super::quoting::{quote_cols_brackets, quote_table_brackets};
use super::SqlServerPlugin;
use crate::engine::identifier::{quote_identifier, IdentifierQuoting};
use crate::error::Result;

use super::super::capabilities::upsert::{
    effective_update_columns, placeholder_list, validate_upsert_inputs, Upsertable,
};

impl Upsertable for SqlServerPlugin {
    fn build_upsert_sql(
        &self,
        table: &str,
        columns: &[&str],
        conflict_columns: &[&str],
        update_columns: Option<&[&str]>,
    ) -> Result<String> {
        validate_upsert_inputs(table, columns, conflict_columns, update_columns)?;
        let qtable = quote_table_brackets(table)?;
        let qcols = quote_cols_brackets(columns)?;
        let placeholders = placeholder_list(columns.len());

        // Source aliases: build "?" placeholders + column aliases
        let alias_list = columns
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier(c, IdentifierQuoting::Brackets)?;
                Ok(format!("? AS {q}"))
            })
            .collect::<Result<Vec<_>>>()?
            .join(", ");
        let _ = placeholders; // alias_list replaces the standard placeholder list

        let on_clause = conflict_columns
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier(c, IdentifierQuoting::Brackets)?;
                Ok(format!("t.{q} = s.{q}"))
            })
            .collect::<Result<Vec<_>>>()?
            .join(" AND ");

        let updates = effective_update_columns(columns, conflict_columns, update_columns);
        let set_clause = if updates.is_empty() {
            String::new()
        } else {
            updates
                .iter()
                .map(|c| -> Result<String> {
                    let q = quote_identifier(c, IdentifierQuoting::Brackets)?;
                    Ok(format!("t.{q} = s.{q}"))
                })
                .collect::<Result<Vec<_>>>()?
                .join(", ")
        };

        let insert_cols = qcols.clone();
        let insert_vals = columns
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier(c, IdentifierQuoting::Brackets)?;
                Ok(format!("s.{q}"))
            })
            .collect::<Result<Vec<_>>>()?
            .join(", ");

        let when_matched = if set_clause.is_empty() {
            String::new()
        } else {
            format!(" WHEN MATCHED THEN UPDATE SET {set_clause}")
        };

        // Note the trailing semicolon: SQL Server requires MERGE to end with `;`.
        Ok(format!(
            "MERGE INTO {qtable} AS t \
             USING (SELECT {alias_list}) AS s \
             ON {on_clause}\
             {when_matched} \
             WHEN NOT MATCHED THEN INSERT ({insert_cols}) VALUES ({insert_vals});"
        ))
    }
}

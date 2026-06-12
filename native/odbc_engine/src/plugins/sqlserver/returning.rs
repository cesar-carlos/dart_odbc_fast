use super::SqlServerPlugin;
use crate::engine::identifier::{quote_identifier, IdentifierQuoting};
use crate::error::Result;

use super::super::capabilities::returning::DmlVerb;
use super::super::capabilities::Returnable;

impl Returnable for SqlServerPlugin {
    fn supports_returning(&self) -> bool {
        true
    }

    fn append_returning_clause(
        &self,
        sql: &str,
        verb: DmlVerb,
        columns: &[&str],
    ) -> Result<String> {
        // SQL Server uses OUTPUT INSERTED.* / DELETED.* / both.
        let prefix = match verb {
            DmlVerb::Insert => "INSERTED",
            DmlVerb::Delete => "DELETED",
            DmlVerb::Update => "INSERTED",
        };
        let cols = columns
            .iter()
            .map(|c| -> Result<String> {
                let q = quote_identifier(c, IdentifierQuoting::Brackets)?;
                Ok(format!("{prefix}.{q}"))
            })
            .collect::<Result<Vec<_>>>()?
            .join(", ");

        // Insert OUTPUT before VALUES/SELECT/WHERE depending on the statement.
        // For INSERT INTO t (...) VALUES (...) — OUTPUT goes between (...) and VALUES.
        let trimmed = sql.trim_end_matches(';').trim_end();
        let upper = trimmed.to_ascii_uppercase();

        if let Some(values_pos) = upper.rfind(" VALUES") {
            let (head, tail) = trimmed.split_at(values_pos);
            return Ok(format!("{head} OUTPUT {cols}{tail}"));
        }
        if let Some(select_pos) = upper.rfind(" SELECT") {
            let (head, tail) = trimmed.split_at(select_pos);
            return Ok(format!("{head} OUTPUT {cols}{tail}"));
        }
        if let Some(set_pos) = upper.find(" SET") {
            // UPDATE t SET ... WHERE ... -> UPDATE t SET ... OUTPUT INSERTED.* WHERE ...
            // Place OUTPUT after the SET clause's value list. Conservative: after WHERE.
            if let Some(where_pos) = upper[set_pos..].find(" WHERE") {
                let abs_where = set_pos + where_pos;
                let (head, tail) = trimmed.split_at(abs_where);
                return Ok(format!("{head} OUTPUT {cols}{tail}"));
            }
            return Ok(format!("{trimmed} OUTPUT {cols}"));
        }
        if upper.starts_with("DELETE") {
            // DELETE FROM t WHERE ... -> DELETE FROM t OUTPUT DELETED.* WHERE ...
            if let Some(where_pos) = upper.find(" WHERE") {
                let (head, tail) = trimmed.split_at(where_pos);
                return Ok(format!("{head} OUTPUT {cols}{tail}"));
            }
            return Ok(format!("{trimmed} OUTPUT {cols}"));
        }
        Ok(format!("{trimmed} OUTPUT {cols}"))
    }
}

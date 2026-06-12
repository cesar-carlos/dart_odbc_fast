use super::Db2Plugin;
use crate::engine::identifier::quote_identifier_default;
use crate::error::{OdbcError, Result};

use super::super::capabilities::returning::DmlVerb;
use super::super::capabilities::Returnable;

impl Returnable for Db2Plugin {
    fn supports_returning(&self) -> bool {
        true
    }

    /// Db2 uses `SELECT ... FROM FINAL TABLE (INSERT ...)` instead of RETURNING.
    fn append_returning_clause(
        &self,
        sql: &str,
        verb: DmlVerb,
        columns: &[&str],
    ) -> Result<String> {
        if !matches!(verb, DmlVerb::Insert | DmlVerb::Update) {
            return Err(OdbcError::UnsupportedFeature(
                "Db2 FROM FINAL TABLE works for INSERT and UPDATE only".to_string(),
            ));
        }
        let proj = columns
            .iter()
            .map(|c| quote_identifier_default(c))
            .collect::<Result<Vec<_>>>()?
            .join(", ");
        let trimmed = sql.trim_end_matches(';');
        Ok(format!("SELECT {proj} FROM FINAL TABLE ({trimmed})"))
    }
}

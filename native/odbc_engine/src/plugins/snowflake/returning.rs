use super::SnowflakePlugin;
use crate::error::Result;

use super::super::capabilities::returning::{quote_returning_columns, DmlVerb};
use super::super::capabilities::Returnable;

impl Returnable for SnowflakePlugin {
    fn supports_returning(&self) -> bool {
        // Available since 2024 in many Snowflake editions; conservative default.
        // Callers can flip via plugin options if needed.
        true
    }

    fn append_returning_clause(
        &self,
        sql: &str,
        _verb: DmlVerb,
        columns: &[&str],
    ) -> Result<String> {
        let proj = quote_returning_columns(columns)?;
        Ok(format!("{} RETURNING {proj}", sql.trim_end_matches(';')))
    }
}

use super::OraclePlugin;
use crate::error::Result;

use super::super::capabilities::returning::{quote_returning_columns, DmlVerb};
use super::super::capabilities::Returnable;

impl Returnable for OraclePlugin {
    fn supports_returning(&self) -> bool {
        true
    }

    /// Oracle uses `RETURNING ... INTO :var` with OUT bind variables — the
    /// resulting clause does NOT produce a result set the caller can fetch.
    fn returns_resultset(&self) -> bool {
        false
    }

    fn append_returning_clause(
        &self,
        sql: &str,
        _verb: DmlVerb,
        columns: &[&str],
    ) -> Result<String> {
        let proj = quote_returning_columns(columns)?;
        // OUT bind variables :ret_<idx> — caller must register them.
        let into_vars = (0..columns.len())
            .map(|i| format!(":ret_{i}"))
            .collect::<Vec<_>>()
            .join(", ");
        Ok(format!(
            "{} RETURNING {proj} INTO {into_vars}",
            sql.trim_end_matches(';')
        ))
    }
}

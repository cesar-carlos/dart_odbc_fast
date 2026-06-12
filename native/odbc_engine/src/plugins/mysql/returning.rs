use super::MySqlPlugin;
use crate::error::{OdbcError, Result};

use super::super::capabilities::returning::DmlVerb;
use super::super::capabilities::Returnable;

impl Returnable for MySqlPlugin {
    /// Stock MySQL (5.7/8.x) does not support RETURNING; MariaDB-only path
    /// lives in a (future) `MariaDbPlugin`.
    fn supports_returning(&self) -> bool {
        false
    }

    fn append_returning_clause(
        &self,
        _sql: &str,
        _verb: DmlVerb,
        _columns: &[&str],
    ) -> Result<String> {
        Err(OdbcError::UnsupportedFeature(
            "MySQL does not support RETURNING; use SELECT LAST_INSERT_ID() instead".to_string(),
        ))
    }
}

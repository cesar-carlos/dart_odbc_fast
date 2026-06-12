use super::SybasePlugin;
use crate::error::{OdbcError, Result};

use super::super::capabilities::returning::DmlVerb;
use super::super::capabilities::Returnable;

impl Returnable for SybasePlugin {
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
            "Sybase does not support RETURNING; use SELECT @@IDENTITY (ASE) instead".to_string(),
        ))
    }
}

use super::SybasePlugin;
use crate::error::{OdbcError, Result};

use super::super::capabilities::upsert::Upsertable;

impl Upsertable for SybasePlugin {
    /// Sybase ASE has no portable single-statement UPSERT; ASA supports MERGE
    /// from version 12+. The base `SybasePlugin` is conservative and rejects;
    /// callers that know they target ASA can use the dedicated `SybaseAsaPlugin`
    /// (added in v3.0 phase 5).
    fn build_upsert_sql(
        &self,
        _table: &str,
        _columns: &[&str],
        _conflict_columns: &[&str],
        _update_columns: Option<&[&str]>,
    ) -> Result<String> {
        Err(OdbcError::UnsupportedFeature(
            "Generic Sybase plugin does not implement UPSERT; \
             use SybaseAsaPlugin (MERGE-capable) when targeting SQL Anywhere"
                .to_string(),
        ))
    }
}

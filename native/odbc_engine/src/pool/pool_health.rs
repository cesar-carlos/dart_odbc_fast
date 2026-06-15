use crate::error::{OdbcError, Result};
use crate::handles::CachedConnection;
use odbc_api::{ConnectionOptions, Environment};
use std::sync::OnceLock;

static GLOBAL_POOL_ENV: OnceLock<std::result::Result<Environment, String>> = OnceLock::new();

pub(crate) fn get_global_pool_env() -> Result<&'static Environment> {
    let env = GLOBAL_POOL_ENV.get_or_init(|| {
        Environment::new().map_err(|e| format!("Failed to create ODBC environment for pool: {}", e))
    });

    match env {
        Ok(environment) => Ok(environment),
        Err(msg) => Err(OdbcError::PoolError(msg.clone())),
    }
}

#[derive(Clone)]
pub(crate) struct OdbcConnectionManager {
    env: &'static Environment,
    connection_string: String,
    health_check_query: String,
}

impl OdbcConnectionManager {
    pub(crate) fn new(connection_string: &str, health_check_query: &str) -> Result<Self> {
        let env = get_global_pool_env()?;
        Ok(Self {
            env,
            connection_string: connection_string.to_string(),
            health_check_query: health_check_query.to_string(),
        })
    }
}

impl r2d2::ManageConnection for OdbcConnectionManager {
    type Connection = CachedConnection;
    type Error = OdbcError;

    fn connect(&self) -> std::result::Result<Self::Connection, Self::Error> {
        let conn = self
            .env
            .connect_with_connection_string(&self.connection_string, ConnectionOptions::default())
            .map_err(OdbcError::from)?;
        Ok(CachedConnection::new(conn))
    }

    fn is_valid(&self, conn: &mut Self::Connection) -> std::result::Result<(), Self::Error> {
        conn.pool_session_reset()?;
        conn.connection()
            .execute(&self.health_check_query, (), None)
            .map(|_| ())
            .map_err(OdbcError::from)
    }

    fn has_broken(&self, conn: &mut Self::Connection) -> bool {
        self.is_valid(conn).is_err()
    }
}

/// Forces `set_autocommit(true)` on every checkout regardless of
/// `test_on_check_out`. Prevents conn reuse in mid-transaction state when
/// validation is disabled.
#[derive(Debug)]
pub(crate) struct PoolAutocommitCustomizer;

impl r2d2::CustomizeConnection<CachedConnection, OdbcError> for PoolAutocommitCustomizer {
    fn on_acquire(&self, conn: &mut CachedConnection) -> std::result::Result<(), OdbcError> {
        conn.pool_session_reset()
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn default_health_check_query_is_select_one() {
        assert_eq!(
            super::super::pool_config::DEFAULT_HEALTH_CHECK_QUERY,
            "SELECT 1"
        );
    }
}

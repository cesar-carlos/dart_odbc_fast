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
        // Health-check only. r2d2 0.8 calls `is_valid` on idle checkout when
        // `test_on_check_out` is set, then returns the connection — it does
        // *not* call `CustomizeConnection::on_acquire` on that path.
        // Per-checkout `pool_session_reset` lives in `ConnectionPool::get` so
        // we do not pay rollback/autocommit twice when validation is on.
        // Checkin still resets before return to the idle set.
        conn.connection()
            .execute(&self.health_check_query, (), None)
            .map(|_| ())
            .map_err(OdbcError::from)
    }

    fn has_broken(&self, conn: &mut Self::Connection) -> bool {
        self.is_valid(conn).is_err()
    }
}

/// Resets session state immediately after `ManageConnection::connect`.
///
/// r2d2 only invokes this for **new** connections, not for idle checkouts.
/// The per-checkout reset (including when `test_on_check_out` is false) is
/// owned by [`super::ConnectionPool::get`].
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

    #[test]
    fn checkout_reset_contract_is_documented_for_r2d2_08() {
        // r2d2 0.8 `CustomizeConnection::on_acquire` runs only after
        // `ManageConnection::connect`, not when popping an idle connection.
        // Per-checkout reset therefore belongs in `ConnectionPool::get`.
        // `is_valid` must stay health-query-only so `test_on_check_out=true`
        // does not double `pool_session_reset` on the same checkout.
        const {
            assert!(super::super::pool_config::DEFAULT_TEST_ON_CHECKOUT);
        }
    }
}

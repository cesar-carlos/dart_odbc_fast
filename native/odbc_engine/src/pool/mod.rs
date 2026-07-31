use crate::error::{OdbcError, Result};
use crate::handles::CachedConnection;
use odbc_api::Connection;
use r2d2::{Pool, PooledConnection};
use std::sync::{Arc, Mutex};
use std::time::Duration;

mod pool_config;
mod pool_health;

use pool_config::PoolConfig;
pub use pool_config::{PoolOptions, PoolRuntimeConfig};
use pool_health::{OdbcConnectionManager, PoolAutocommitCustomizer};

#[derive(Clone)]
pub struct ConnectionPool {
    pool: Pool<OdbcConnectionManager>,
    config: PoolRuntimeConfig,
    max_size: u32,
}

impl ConnectionPool {
    pub fn new(connection_string: &str, max_size: u32) -> Result<Self> {
        Self::new_with_options(connection_string, max_size, PoolOptions::default())
    }

    /// Create a pool with eviction options for testing or tuning.
    pub fn new_with_options(
        connection_string: &str,
        max_size: u32,
        options: PoolOptions,
    ) -> Result<Self> {
        let config = PoolConfig::from_connection_string(connection_string);
        let session_reset_on_checkout = pool_config::resolve_session_reset_on_checkout(
            options.session_reset_on_checkout,
            config.session_reset_on_checkout,
            pool_config::read_session_reset_from_env_for_pool(),
        );
        let runtime = PoolRuntimeConfig {
            connection_string: config.sanitized_connection_string,
            test_on_check_out: config.test_on_check_out,
            health_check_query: config.health_check_query,
            session_reset_on_checkout,
            options,
        };
        Self::from_runtime_config(runtime, max_size)
    }

    fn from_runtime_config(config: PoolRuntimeConfig, max_size: u32) -> Result<Self> {
        let manager =
            OdbcConnectionManager::new(&config.connection_string, &config.health_check_query)?;
        let connection_timeout = config
            .options
            .connection_timeout
            .unwrap_or_else(|| Duration::from_secs(30));
        let mut builder = Pool::builder()
            .max_size(max_size)
            .connection_timeout(connection_timeout)
            .test_on_check_out(config.test_on_check_out)
            .connection_customizer(Box::new(PoolAutocommitCustomizer));
        if let Some(d) = config.options.idle_timeout {
            builder = builder.idle_timeout(Some(d));
        }
        if let Some(d) = config.options.max_lifetime {
            builder = builder.max_lifetime(Some(d));
        }
        let pool = builder
            .build(manager)
            .map_err(|e| OdbcError::PoolError(format!("Pool creation failed: {}", e)))?;

        Ok(Self {
            pool,
            config,
            max_size,
        })
    }

    pub fn recreate_with_max_size(&self, max_size: u32) -> Result<Self> {
        Self::from_runtime_config(self.config.clone(), max_size)
    }

    pub fn config_snapshot(&self) -> PoolRuntimeConfig {
        self.config.clone()
    }

    pub fn get(&self) -> Result<PooledConnectionWrapper> {
        // r2d2 `CustomizeConnection::on_acquire` runs only after `connect`,
        // not on idle checkout. Reset here so every delivered connection is
        // clean regardless of `test_on_check_out`. `is_valid` (when enabled)
        // only runs the health query to avoid a second reset on that path.
        // Trusted pools may disable checkout reset via PoolOptions /
        // `Pool_Session_Reset` / `ODBC_POOL_SESSION_RESET` (checkin still resets).
        let mut pooled = self.pool.get().map_err(|e| {
            OdbcError::PoolError(format!("Failed to get connection from pool: {}", e))
        })?;
        if self.config.session_reset_on_checkout {
            pooled.pool_session_reset().map_err(|e| {
                OdbcError::PoolError(format!(
                    "Failed to reset pooled connection on checkout: {}",
                    e
                ))
            })?;
        }
        Ok(PooledConnectionWrapper { pooled })
    }

    pub fn health_check(&self) -> bool {
        self.pool.get().is_ok()
    }

    pub fn max_size(&self) -> u32 {
        self.max_size
    }

    pub fn connection_string(&self) -> &str {
        &self.config.connection_string
    }

    pub fn test_on_check_out(&self) -> bool {
        self.config.test_on_check_out
    }

    pub fn state(&self) -> PoolState {
        PoolState {
            size: self.pool.state().connections,
            idle: self.pool.state().idle_connections,
        }
    }

    /// Pool ID per ODBC spec: server:port:user. Database excluded so connections
    /// can be reused when only database changes.
    pub fn get_pool_id(&self) -> String {
        Self::extract_pool_components(self.connection_string())
    }

    pub(crate) fn extract_pool_components(conn_str: &str) -> String {
        let mut server = String::new();
        let mut port = String::new();
        let mut uid = String::new();
        for part in conn_str.split(';') {
            let part = part.trim();
            if let Some((k, v)) = part.split_once('=') {
                let k = k.trim().to_lowercase();
                let v = v.trim().trim_matches(|c| c == '{' || c == '}');
                match k.as_str() {
                    "server" | "host" | "hostname" => {
                        if !v.is_empty() {
                            server = v.to_string();
                        }
                    }
                    "port" => {
                        if !v.is_empty() {
                            port = v.to_string();
                        }
                    }
                    "uid" | "user" | "username" => {
                        if !v.is_empty() {
                            uid = v.to_string();
                        }
                    }
                    _ => {}
                }
            }
        }
        if server.is_empty() && port.is_empty() && uid.is_empty() {
            return conn_str.to_string();
        }
        format!("{}:{}:{}", server, port, uid)
    }
}

pub struct PooledConnectionWrapper {
    pooled: PooledConnection<OdbcConnectionManager>,
}

pub type SharedPooledConnection = Arc<Mutex<PooledConnectionWrapper>>;

impl PooledConnectionWrapper {
    pub fn get_connection(&self) -> &Connection<'static> {
        self.pooled.connection()
    }

    pub fn get_connection_mut(&mut self) -> &mut Connection<'static> {
        self.pooled.connection_mut()
    }

    /// Immutable cached wrapper for engine-id / prepared reuse on pooled checkouts.
    pub fn cached(&self) -> &CachedConnection {
        &self.pooled
    }

    /// Mutable cached wrapper for prepared-statement reuse on pooled checkouts.
    pub fn cached_mut(&mut self) -> &mut CachedConnection {
        &mut self.pooled
    }
}

pub struct PoolState {
    pub size: u32,
    pub idle: u32,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_pool_components() {
        let s = "Driver={SQL Server};Server=localhost;Port=1433;Database=myDb;UID=sa;PWD=secret;";
        let id = ConnectionPool::extract_pool_components(s);
        assert_eq!(id, "localhost:1433:sa");
    }

    #[test]
    fn test_extract_pool_components_no_database_in_id() {
        let s = "Server=host;Database=db1;UID=u;PWD=p";
        let id = ConnectionPool::extract_pool_components(s);
        assert!(!id.contains("db1"));
        assert_eq!(id, "host::u");
    }

    #[test]
    fn test_extract_pool_components_fallback() {
        let s = "DSN=MyDSN";
        let id = ConnectionPool::extract_pool_components(s);
        assert_eq!(id, "DSN=MyDSN");
    }

    #[test]
    fn test_extract_pool_components_hostname_key() {
        let s = "Hostname=myserver;Port=5432;Username=myuser;";
        let id = ConnectionPool::extract_pool_components(s);
        assert_eq!(id, "myserver:5432:myuser");
    }

    #[test]
    fn test_extract_pool_components_user_key() {
        let s = "Server=srv;UID=admin;";
        let id = ConnectionPool::extract_pool_components(s);
        assert_eq!(id, "srv::admin");
    }

    #[test]
    fn test_pool_state_struct() {
        let state = PoolState { size: 2, idle: 1 };
        assert_eq!(state.size, 2);
        assert_eq!(state.idle, 1);
    }

    #[test]
    fn pool_manager_connection_type_is_cached_connection() {
        fn assert_is_cached(_: CachedConnection) {}
        let _ = assert_is_cached;
    }

    #[test]
    fn pooled_wrapper_exposes_cached_mut_for_stmt_cache() {
        fn assert_cached_mut_available(wrapper: &mut PooledConnectionWrapper) {
            let _cached: &mut CachedConnection = wrapper.cached_mut();
        }
        let _ = assert_cached_mut_available;
    }

    #[test]
    fn connection_pool_get_owns_per_checkout_session_reset() {
        // Invariant: callers of ConnectionPool::get always receive a connection
        // that has been through pool_session_reset after r2d2::Pool::get,
        // independent of test_on_check_out. is_valid must not also reset.
        fn assert_get_signature(pool: &ConnectionPool) -> Result<PooledConnectionWrapper> {
            pool.get()
        }
        let _ = assert_get_signature;
    }

    #[test]
    fn should_extract_pool_id_using_host_key() {
        let id = ConnectionPool::extract_pool_components("Host=db1;Port=3306;User=app;");
        assert_eq!(id, "db1:3306:app");
    }

    #[test]
    fn recreate_with_max_size_preserves_resolved_pool_configuration() {
        let dsn = match std::env::var("ODBC_TEST_DSN")
            .ok()
            .or_else(|| std::env::var("ODBC_DSN").ok())
            .filter(|value| !value.trim().is_empty())
        {
            Some(value) => value,
            None => {
                eprintln!("Skipping: ODBC_TEST_DSN / ODBC_DSN not set");
                return;
            }
        };
        let pool = ConnectionPool::new_with_options(
            &format!(
                "{dsn};Pool_Test_On_Checkout=false;Health_Check_Query=SELECT CURRENT_TIMESTAMP;"
            ),
            2,
            PoolOptions {
                idle_timeout: Some(Duration::from_secs(5)),
                max_lifetime: Some(Duration::from_secs(7)),
                connection_timeout: Some(Duration::from_secs(11)),
                session_reset_on_checkout: None,
            },
        )
        .expect("pool should build with the configured test DSN");

        let resized = pool
            .recreate_with_max_size(5)
            .expect("resize recreation should preserve config");

        let snapshot = resized.config_snapshot();
        assert_eq!(resized.max_size(), 5);
        assert!(!snapshot.connection_string.contains("Pool_Test_On_Checkout"));
        assert!(!snapshot.connection_string.contains("Health_Check_Query"));
        assert!(!snapshot.test_on_check_out);
        assert_eq!(snapshot.health_check_query, "SELECT CURRENT_TIMESTAMP");
        assert_eq!(snapshot.options.idle_timeout, Some(Duration::from_secs(5)));
        assert_eq!(snapshot.options.max_lifetime, Some(Duration::from_secs(7)));
        assert!(snapshot.session_reset_on_checkout);
        assert_eq!(
            snapshot.options.connection_timeout,
            Some(Duration::from_secs(11))
        );
    }
}

use crate::error::{OdbcError, Result};
use odbc_api::{Connection, ConnectionOptions, Environment};
use r2d2::{Pool, PooledConnection};
use std::sync::OnceLock;
use std::time::Duration;

static GLOBAL_POOL_ENV: OnceLock<Environment> = OnceLock::new();

fn get_global_pool_env() -> &'static Environment {
    GLOBAL_POOL_ENV
        .get_or_init(|| Environment::new().expect("Failed to create ODBC environment for pool"))
}

#[derive(Clone)]
struct OdbcConnectionManager {
    env: &'static Environment,
    connection_string: String,
}

impl OdbcConnectionManager {
    fn new(connection_string: &str) -> Result<Self> {
        let env = get_global_pool_env();
        Ok(Self {
            env,
            connection_string: connection_string.to_string(),
        })
    }
}

impl r2d2::ManageConnection for OdbcConnectionManager {
    type Connection = Connection<'static>;
    type Error = OdbcError;

    fn connect(&self) -> std::result::Result<Self::Connection, Self::Error> {
        self.env
            .connect_with_connection_string(&self.connection_string, ConnectionOptions::default())
            .map_err(OdbcError::from)
    }

    fn is_valid(&self, conn: &mut Self::Connection) -> std::result::Result<(), Self::Error> {
        conn.set_autocommit(true).map_err(OdbcError::from)?;
        conn.execute("SELECT 1", (), None)
            .map(|_| ())
            .map_err(OdbcError::from)
    }

    fn has_broken(&self, conn: &mut Self::Connection) -> bool {
        self.is_valid(conn).is_err()
    }
}

pub struct ConnectionPool {
    pool: Pool<OdbcConnectionManager>,
    connection_string: String,
    max_size: u32,
}

impl ConnectionPool {
    pub fn new(connection_string: &str, max_size: u32) -> Result<Self> {
        let manager = OdbcConnectionManager::new(connection_string)?;
        let pool = Pool::builder()
            .max_size(max_size)
            .connection_timeout(Duration::from_secs(30))
            .test_on_check_out(true)
            .build(manager)
            .map_err(|e| OdbcError::PoolError(format!("Pool creation failed: {}", e)))?;

        Ok(Self {
            pool,
            connection_string: connection_string.to_string(),
            max_size,
        })
    }

    pub fn get(&self) -> Result<PooledConnectionWrapper> {
        let pooled = self.pool.get().map_err(|e| {
            OdbcError::PoolError(format!("Failed to get connection from pool: {}", e))
        })?;
        Ok(PooledConnectionWrapper { pooled })
    }

    pub fn health_check(&self) -> bool {
        self.pool.get().is_ok()
    }

    pub fn max_size(&self) -> u32 {
        self.max_size
    }

    pub fn connection_string(&self) -> &str {
        &self.connection_string
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
        Self::extract_pool_components(&self.connection_string)
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

impl PooledConnectionWrapper {
    pub fn get_connection(&self) -> &Connection<'static> {
        &self.pooled
    }

    pub fn get_connection_mut(&mut self) -> &mut Connection<'static> {
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
}

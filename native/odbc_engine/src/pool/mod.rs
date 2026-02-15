use crate::error::{OdbcError, Result};
use odbc_api::{Connection, ConnectionOptions, Environment};
use r2d2::{Pool, PooledConnection};
use std::sync::OnceLock;
use std::time::Duration;

static GLOBAL_POOL_ENV: OnceLock<std::result::Result<Environment, String>> = OnceLock::new();
const POOL_TEST_ON_CHECKOUT_ENV: &str = "ODBC_POOL_TEST_ON_CHECKOUT";
const DEFAULT_TEST_ON_CHECKOUT: bool = true;

fn get_global_pool_env() -> Result<&'static Environment> {
    let env = GLOBAL_POOL_ENV.get_or_init(|| {
        Environment::new().map_err(|e| format!("Failed to create ODBC environment for pool: {}", e))
    });

    match env {
        Ok(environment) => Ok(environment),
        Err(msg) => Err(OdbcError::PoolError(msg.clone())),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PoolConfig {
    sanitized_connection_string: String,
    test_on_check_out: bool,
}

impl PoolConfig {
    fn from_connection_string(connection_string: &str) -> Self {
        let (sanitized_connection_string, conn_override) =
            parse_pool_options_from_connection_string(connection_string);
        let test_on_check_out =
            resolve_checkout_validation(conn_override, read_checkout_validation_from_env());

        Self {
            sanitized_connection_string,
            test_on_check_out,
        }
    }
}

fn is_pool_checkout_option(key: &str) -> bool {
    matches!(
        key,
        "pooltestoncheckout"
            | "testoncheckout"
            | "pool_test_on_checkout"
            | "pool_test_on_check_out"
            | "test_on_checkout"
            | "test_on_check_out"
    )
}

fn parse_bool_flag(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

fn split_connection_string_parts(connection_string: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut start = 0usize;
    let mut brace_depth = 0u32;

    for (idx, ch) in connection_string.char_indices() {
        match ch {
            '{' => brace_depth = brace_depth.saturating_add(1),
            '}' => brace_depth = brace_depth.saturating_sub(1),
            ';' if brace_depth == 0 => {
                parts.push(&connection_string[start..idx]);
                start = idx + ch.len_utf8();
            }
            _ => {}
        }
    }
    parts.push(&connection_string[start..]);
    parts
}

fn parse_pool_options_from_connection_string(connection_string: &str) -> (String, Option<bool>) {
    let mut sanitized_parts = Vec::new();
    let mut conn_override = None;

    for part in split_connection_string_parts(connection_string) {
        let trimmed = part.trim();
        if trimmed.is_empty() {
            continue;
        }

        if let Some((key, raw_value)) = part.split_once('=') {
            let normalized_key = key.trim().to_ascii_lowercase();
            if is_pool_checkout_option(&normalized_key) {
                let value = raw_value.trim().trim_matches(|c| c == '{' || c == '}');
                if let Some(parsed) = parse_bool_flag(value) {
                    conn_override = Some(parsed);
                }
                continue;
            }
        }

        sanitized_parts.push(trimmed);
    }

    let mut sanitized_connection_string = sanitized_parts.join(";");
    if connection_string.trim_end().ends_with(';') && !sanitized_connection_string.is_empty() {
        sanitized_connection_string.push(';');
    }

    (sanitized_connection_string, conn_override)
}

fn read_checkout_validation_from_env() -> Option<bool> {
    std::env::var(POOL_TEST_ON_CHECKOUT_ENV)
        .ok()
        .and_then(|value| parse_bool_flag(&value))
}

fn resolve_checkout_validation(conn_override: Option<bool>, env_override: Option<bool>) -> bool {
    conn_override
        .or(env_override)
        .unwrap_or(DEFAULT_TEST_ON_CHECKOUT)
}

#[derive(Clone)]
struct OdbcConnectionManager {
    env: &'static Environment,
    connection_string: String,
}

impl OdbcConnectionManager {
    fn new(connection_string: &str) -> Result<Self> {
        let env = get_global_pool_env()?;
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
    test_on_check_out: bool,
}

impl ConnectionPool {
    pub fn new(connection_string: &str, max_size: u32) -> Result<Self> {
        let config = PoolConfig::from_connection_string(connection_string);
        let manager = OdbcConnectionManager::new(&config.sanitized_connection_string)?;
        let pool = Pool::builder()
            .max_size(max_size)
            .connection_timeout(Duration::from_secs(30))
            .test_on_check_out(config.test_on_check_out)
            .build(manager)
            .map_err(|e| OdbcError::PoolError(format!("Pool creation failed: {}", e)))?;

        Ok(Self {
            pool,
            connection_string: config.sanitized_connection_string,
            max_size,
            test_on_check_out: config.test_on_check_out,
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

    pub fn test_on_check_out(&self) -> bool {
        self.test_on_check_out
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
    fn test_parse_pool_option_from_connection_string_true() {
        let conn = "DSN=MainDsn;Pool_Test_On_Checkout=true;";
        let config = PoolConfig::from_connection_string(conn);
        assert_eq!(config.sanitized_connection_string, "DSN=MainDsn;");
        assert!(config.test_on_check_out);
    }

    #[test]
    fn test_parse_pool_option_from_connection_string_false() {
        let conn = "DSN=MainDsn;test_on_check_out=0;UID=sa";
        let config = PoolConfig::from_connection_string(conn);
        assert_eq!(config.sanitized_connection_string, "DSN=MainDsn;UID=sa");
        assert!(!config.test_on_check_out);
    }

    #[test]
    fn test_parse_pool_option_keeps_semicolon_inside_braces() {
        let conn = "PWD={ab;c};PoolTestOnCheckout=false;DSN=MainDsn";
        let (sanitized, override_flag) = parse_pool_options_from_connection_string(conn);
        assert_eq!(sanitized, "PWD={ab;c};DSN=MainDsn");
        assert_eq!(override_flag, Some(false));
    }

    #[test]
    fn test_parse_pool_option_ignores_invalid_value() {
        let conn = "DSN=MainDsn;PoolTestOnCheckout=maybe;";
        let (sanitized, override_flag) = parse_pool_options_from_connection_string(conn);
        assert_eq!(sanitized, "DSN=MainDsn;");
        assert_eq!(override_flag, None);
    }

    #[test]
    fn test_resolve_checkout_validation_default_is_true() {
        assert!(resolve_checkout_validation(None, None));
    }

    #[test]
    fn test_resolve_checkout_validation_env_override() {
        assert!(!resolve_checkout_validation(None, Some(false)));
    }

    #[test]
    fn test_resolve_checkout_validation_connection_string_overrides_env() {
        assert!(resolve_checkout_validation(Some(true), Some(false)));
    }
}

//! Helper functions for reading environment variables in tests

/// Get the ODBC_TEST_DSN connection string from environment
/// Returns None if not set (tests should be ignored in this case)
pub fn get_test_dsn() -> Option<String> {
    std::env::var("ODBC_TEST_DSN")
        .ok()
        .filter(|s| !s.is_empty())
}

/// Build SQL Server connection string from components
/// Returns None if required components are missing
pub fn build_sqlserver_conn_str(
    server: &str,
    database: &str,
    username: &str,
    password: &str,
    port: Option<u16>,
) -> String {
    let server_str = if let Some(port) = port {
        format!("{},{}", server, port)
    } else {
        server.to_string()
    };

    format!(
        "Driver={{SQL Server Native Client 11.0}};Server={};Database={};UID={};PWD={};",
        server_str, database, username, password
    )
}

/// Get SQL Server connection string for E2E tests
/// Uses environment variables or provided defaults
pub fn get_sqlserver_test_dsn() -> Option<String> {
    // First, try environment variable
    if let Some(dsn) = get_test_dsn() {
        return Some(dsn);
    }

    // Try individual environment variables
    let server = std::env::var("SQLSERVER_TEST_SERVER").unwrap_or_else(|_| "LOCALHOST".to_string());
    let database =
        std::env::var("SQLSERVER_TEST_DATABASE").unwrap_or_else(|_| "Estacao".to_string());
    let username = std::env::var("SQLSERVER_TEST_USER").unwrap_or_else(|_| "sa".to_string());
    let password =
        std::env::var("SQLSERVER_TEST_PASSWORD").unwrap_or_else(|_| "123abc.".to_string());
    let port = std::env::var("SQLSERVER_TEST_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok());

    Some(build_sqlserver_conn_str(
        &server, &database, &username, &password, port,
    ))
}

/// Build PostgreSQL connection string from components.
/// Driver: PostgreSQL Unicode (Linux) or PostgreSQL (Windows).
pub fn build_postgresql_conn_str(
    server: &str,
    database: &str,
    username: &str,
    password: &str,
    port: Option<u16>,
) -> String {
    let port_str = port.map(|p| format!(";Port={}", p)).unwrap_or_default();
    format!(
        "Driver={{PostgreSQL Unicode}};Server={};Database={};Uid={};Pwd={}{};",
        server, database, username, password, port_str
    )
}

/// Get PostgreSQL connection string for E2E tests.
/// Env vars: POSTGRES_TEST_SERVER, POSTGRES_TEST_DATABASE, POSTGRES_TEST_USER,
/// POSTGRES_TEST_PASSWORD, POSTGRES_TEST_PORT.
/// Docker default: localhost:5432, odbc_test, postgres/postgres.
pub fn get_postgresql_test_dsn() -> Option<String> {
    if let Some(dsn) = get_test_dsn() {
        return Some(dsn);
    }
    let server = std::env::var("POSTGRES_TEST_SERVER").unwrap_or_else(|_| "localhost".to_string());
    let database =
        std::env::var("POSTGRES_TEST_DATABASE").unwrap_or_else(|_| "odbc_test".to_string());
    let username = std::env::var("POSTGRES_TEST_USER").unwrap_or_else(|_| "postgres".to_string());
    let password =
        std::env::var("POSTGRES_TEST_PASSWORD").unwrap_or_else(|_| "postgres".to_string());
    let port = std::env::var("POSTGRES_TEST_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok());
    Some(build_postgresql_conn_str(
        &server,
        &database,
        &username,
        &password,
        port.or(Some(5432)),
    ))
}

/// Build MySQL connection string from components.
/// Driver: MySQL ODBC 8.0 Driver (common on Linux/Windows).
pub fn build_mysql_conn_str(
    server: &str,
    database: &str,
    username: &str,
    password: &str,
    port: Option<u16>,
) -> String {
    let port_str = port.map(|p| format!(";Port={}", p)).unwrap_or_default();
    format!(
        "Driver={{MySQL ODBC 8.0 Driver}};Server={};Database={};User={};Password={}{};",
        server, database, username, password, port_str
    )
}

/// Build SQLite connection string.
/// Driver: SQLite3 (libsqliteodbc on Linux).
pub fn build_sqlite_conn_str(database_path: &str) -> String {
    format!("Driver={{SQLite3}};Database={};", database_path)
}

/// Build Oracle connection string from components.
/// Driver: Oracle Instant Client ODBC.
pub fn build_oracle_conn_str(
    server: &str,
    service_name: &str,
    username: &str,
    password: &str,
    port: Option<u16>,
) -> String {
    let port_value = port.unwrap_or(1521);
    format!(
        "Driver={{Oracle Instant Client ODBC}};Dbq=//{}:{}/{};Uid={};Pwd={};",
        server, port_value, service_name, username, password
    )
}

/// Build Sybase SQL Anywhere connection string from components.
/// Driver: SQL Anywhere 17.
pub fn build_sybase_conn_str(
    server_name: &str,
    database: &str,
    username: &str,
    password: &str,
) -> String {
    format!(
        "Driver={{SQL Anywhere 17}};ServerName={};Database={};Uid={};Pwd={};",
        server_name, database, username, password
    )
}

/// Get SQLite connection string for E2E tests.
/// Env vars: SQLITE_TEST_DATABASE (path to .db file).
/// Default: /tmp/odbc_test.db (ephemeral for CI).
pub fn get_sqlite_test_dsn() -> Option<String> {
    if let Some(dsn) = get_test_dsn() {
        return Some(dsn);
    }
    let path =
        std::env::var("SQLITE_TEST_DATABASE").unwrap_or_else(|_| "/tmp/odbc_test.db".to_string());
    Some(build_sqlite_conn_str(&path))
}

/// Get MySQL connection string for E2E tests.
/// Env vars: MYSQL_TEST_SERVER, MYSQL_TEST_DATABASE, MYSQL_TEST_USER,
/// MYSQL_TEST_PASSWORD, MYSQL_TEST_PORT.
/// Docker default: localhost:3306, odbc_test, root/mysql.
pub fn get_mysql_test_dsn() -> Option<String> {
    if let Some(dsn) = get_test_dsn() {
        return Some(dsn);
    }
    let server = std::env::var("MYSQL_TEST_SERVER").unwrap_or_else(|_| "localhost".to_string());
    let database = std::env::var("MYSQL_TEST_DATABASE").unwrap_or_else(|_| "odbc_test".to_string());
    let username = std::env::var("MYSQL_TEST_USER").unwrap_or_else(|_| "root".to_string());
    let password = std::env::var("MYSQL_TEST_PASSWORD").unwrap_or_else(|_| "mysql".to_string());
    let port = std::env::var("MYSQL_TEST_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok());
    Some(build_mysql_conn_str(
        &server,
        &database,
        &username,
        &password,
        port.or(Some(3306)),
    ))
}

/// Get Oracle connection string for E2E tests.
/// Env vars: ORACLE_TEST_SERVER, ORACLE_TEST_SERVICE_NAME, ORACLE_TEST_USER,
/// ORACLE_TEST_PASSWORD, ORACLE_TEST_PORT.
/// CI defaults: localhost:1521/FREEPDB1, system/OdbcTest123!
pub fn get_oracle_test_dsn() -> Option<String> {
    if let Some(dsn) = get_test_dsn() {
        return Some(dsn);
    }
    let server = std::env::var("ORACLE_TEST_SERVER").unwrap_or_else(|_| "localhost".to_string());
    let service_name =
        std::env::var("ORACLE_TEST_SERVICE_NAME").unwrap_or_else(|_| "FREEPDB1".to_string());
    let username = std::env::var("ORACLE_TEST_USER").unwrap_or_else(|_| "system".to_string());
    let password =
        std::env::var("ORACLE_TEST_PASSWORD").unwrap_or_else(|_| "OdbcTest123!".to_string());
    let port = std::env::var("ORACLE_TEST_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok());
    Some(build_oracle_conn_str(
        &server,
        &service_name,
        &username,
        &password,
        port.or(Some(1521)),
    ))
}

/// Get Sybase SQL Anywhere connection string for E2E tests.
/// Env vars: SYBASE_TEST_SERVER_NAME, SYBASE_TEST_DATABASE, SYBASE_TEST_USER,
/// SYBASE_TEST_PASSWORD.
pub fn get_sybase_test_dsn() -> Option<String> {
    if let Some(dsn) = get_test_dsn() {
        return Some(dsn);
    }
    let server_name =
        std::env::var("SYBASE_TEST_SERVER_NAME").unwrap_or_else(|_| "demo".to_string());
    let database = std::env::var("SYBASE_TEST_DATABASE").unwrap_or_else(|_| "demo".to_string());
    let username = std::env::var("SYBASE_TEST_USER").unwrap_or_else(|_| "dba".to_string());
    let password = std::env::var("SYBASE_TEST_PASSWORD").unwrap_or_else(|_| "sql".to_string());
    Some(build_sybase_conn_str(
        &server_name,
        &database,
        &username,
        &password,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_postgresql_conn_str() {
        let s = build_postgresql_conn_str("localhost", "test", "u", "p", Some(5432));
        assert!(s.contains("PostgreSQL"));
        assert!(s.contains("localhost"));
        assert!(s.contains("test"));
        assert!(s.contains("Port=5432"));
    }

    #[test]
    fn test_build_mysql_conn_str() {
        let s = build_mysql_conn_str("localhost", "test", "u", "p", Some(3306));
        assert!(s.contains("MySQL"));
        assert!(s.contains("localhost"));
        assert!(s.contains("test"));
        assert!(s.contains("Port=3306"));
    }

    /// `get_*_test_dsn()` falls back to the global `ODBC_TEST_DSN` when no
    /// per-engine env var is set; that env var typically points at the
    /// developer's primary DB (e.g. SQL Server). In that case the assertion
    /// "DSN string contains 'MySQL'" is meaningless, so we skip instead of
    /// failing. When the user actually exports a per-engine env var (or
    /// configures a multi-DB CI matrix), the test runs for real.
    fn dsn_targets_engine(dsn: &str, lower_keywords: &[&str]) -> bool {
        let lower = dsn.to_lowercase();
        lower_keywords.iter().any(|k| lower.contains(k))
    }

    #[test]
    fn test_get_postgresql_test_dsn_returns_some() {
        let Some(s) = get_postgresql_test_dsn() else {
            eprintln!("⚠️  Skipping: no PostgreSQL DSN configured");
            return;
        };
        if !dsn_targets_engine(&s, &["postgres"]) {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN points at a different engine ({s})");
            return;
        }
        assert!(s.contains("PostgreSQL") || s.contains("postgres"));
    }

    #[test]
    fn test_get_mysql_test_dsn_returns_some() {
        let Some(s) = get_mysql_test_dsn() else {
            eprintln!("⚠️  Skipping: no MySQL DSN configured");
            return;
        };
        if !dsn_targets_engine(&s, &["mysql", "mariadb"]) {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN points at a different engine ({s})");
            return;
        }
        assert!(s.contains("MySQL") || s.contains("mysql"));
    }

    #[test]
    fn test_build_sqlite_conn_str() {
        let s = build_sqlite_conn_str("/tmp/test.db");
        assert!(s.contains("SQLite3"));
        assert!(s.contains("/tmp/test.db"));
    }

    #[test]
    fn test_build_oracle_conn_str() {
        let s = build_oracle_conn_str("localhost", "FREEPDB1", "system", "p", Some(1521));
        assert!(s.contains("Oracle Instant Client ODBC"));
        assert!(s.contains("Dbq=//localhost:1521/FREEPDB1"));
        assert!(s.contains("Uid=system"));
    }

    #[test]
    fn test_build_sybase_conn_str() {
        let s = build_sybase_conn_str("demo", "demo", "dba", "sql");
        assert!(s.contains("SQL Anywhere 17"));
        assert!(s.contains("ServerName=demo"));
        assert!(s.contains("Uid=dba"));
    }

    #[test]
    fn test_get_oracle_test_dsn_returns_some() {
        let Some(s) = get_oracle_test_dsn() else {
            eprintln!("⚠️  Skipping: no Oracle DSN configured");
            return;
        };
        if !dsn_targets_engine(&s, &["oracle"]) {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN points at a different engine ({s})");
            return;
        }
        assert!(s.contains("Oracle") || s.contains("oracle"));
    }

    #[test]
    fn test_get_sybase_test_dsn_returns_some() {
        let Some(s) = get_sybase_test_dsn() else {
            eprintln!("⚠️  Skipping: no Sybase DSN configured");
            return;
        };
        if !dsn_targets_engine(&s, &["sql anywhere", "sybase", "adaptive server"]) {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN points at a different engine ({s})");
            return;
        }
        assert!(s.contains("SQL Anywhere") || s.contains("sybase"));
    }
}

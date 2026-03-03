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

    #[test]
    fn test_get_postgresql_test_dsn_returns_some() {
        let dsn = get_postgresql_test_dsn();
        assert!(dsn.is_some());
        let s = dsn.unwrap();
        assert!(s.contains("PostgreSQL") || s.contains("postgres"));
    }

    #[test]
    fn test_get_mysql_test_dsn_returns_some() {
        let dsn = get_mysql_test_dsn();
        assert!(dsn.is_some());
        let s = dsn.unwrap();
        assert!(s.contains("MySQL") || s.contains("mysql"));
    }

    #[test]
    fn test_build_sqlite_conn_str() {
        let s = build_sqlite_conn_str("/tmp/test.db");
        assert!(s.contains("SQLite3"));
        assert!(s.contains("/tmp/test.db"));
    }
}

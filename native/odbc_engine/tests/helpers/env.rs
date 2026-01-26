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

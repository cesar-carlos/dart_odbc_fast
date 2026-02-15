/// Helper functions for E2E tests.
/// Provides utilities to check whether E2E tests can run (connection available).
use super::env::get_sqlserver_test_dsn;
use odbc_engine::engine::{OdbcConnection, OdbcEnvironment};
use odbc_engine::test_helpers::load_dotenv;

/// Detected database type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DatabaseType {
    SqlServer,
    Sybase,
    PostgreSQL,
    MySQL,
    Oracle,
    MongoDB,
    SQLite,
    Unknown,
}

/// Detects database type from the connection string.
pub fn detect_database_type(conn_str: &str) -> DatabaseType {
    let conn_lower = conn_str.to_lowercase();

    // SQL Server - several possible drivers.
    if conn_lower.contains("sql server")
        || conn_lower.contains("driver={odbc driver")
        || (conn_lower.contains("server=")
            && conn_lower.contains("database=")
            && !conn_lower.contains("sql anywhere"))
    {
        return DatabaseType::SqlServer;
    }

    // Sybase Anywhere.
    if conn_lower.contains("sql anywhere")
        || conn_lower.contains("sybase")
        || conn_lower.contains("servername=")
    {
        return DatabaseType::Sybase;
    }

    // PostgreSQL.
    if conn_lower.contains("postgresql") {
        return DatabaseType::PostgreSQL;
    }

    // MySQL.
    if conn_lower.contains("mysql") {
        return DatabaseType::MySQL;
    }

    // Oracle.
    if conn_lower.contains("oracle") {
        return DatabaseType::Oracle;
    }

    // MongoDB (ODBC connector).
    if conn_lower.contains("mongodb") {
        return DatabaseType::MongoDB;
    }

    // SQLite.
    if conn_lower.contains("sqlite") {
        return DatabaseType::SQLite;
    }

    DatabaseType::Unknown
}

/// Gets the connection string and detected database type.
#[allow(dead_code)]
pub fn get_connection_and_db_type() -> Option<(String, DatabaseType)> {
    load_dotenv();

    let conn_str = get_sqlserver_test_dsn()?;
    let db_type = detect_database_type(&conn_str);

    Some((conn_str, db_type))
}

/// Checks whether an E2E database connection can be established.
/// Returns `true` when the connection is available and working.
#[allow(dead_code)] // Test helper API; used by e2e tests when ODBC is configured
pub fn can_connect_to_sqlserver() -> bool {
    // Load variables from .env.
    load_dotenv();

    // Verify whether connection string is available.
    let conn_str = match get_sqlserver_test_dsn() {
        Some(s) => s,
        None => {
            return false;
        }
    };

    // Try to initialize ODBC environment.
    let env = OdbcEnvironment::new();
    if env.init().is_err() {
        return false;
    }

    // Try to connect to database.
    let handles = env.get_handles();
    match OdbcConnection::connect(handles, &conn_str) {
        Ok(conn) => {
            // Connected successfully, disconnect and return true.
            let _ = conn.disconnect();
            let db_type = detect_database_type(&conn_str);
            eprintln!(
                "[OK] Connection successful with: {} (detected as {:?})",
                conn_str, db_type
            );
            true
        }
        Err(e) => {
            eprintln!("[ERROR] Connection failed: {:?}", e);
            eprintln!("  Connection string: {}", conn_str);
            false
        }
    }
}

/// Checks whether a test should run for a specific database type.
/// Returns true when the connected database matches the expected one.
#[allow(dead_code)]
pub fn is_database_type(expected: DatabaseType) -> bool {
    load_dotenv();

    if let Some((_conn_str, db_type)) = get_connection_and_db_type() {
        if db_type == expected {
            return true;
        } else {
            eprintln!(
                "[WARN] Skipping test: requires {:?}, but connected to {:?}",
                expected, db_type
            );
            return false;
        }
    }

    false
}

/// Checks whether E2E tests should run.
/// Runs only when ENABLE_E2E_TESTS is explicitly enabled.
#[allow(dead_code)] // Test helper API; used by e2e tests when ENABLE_E2E_TESTS is set
pub fn should_run_e2e_tests() -> bool {
    // Load variables from .env.
    load_dotenv();

    fn parse_env_bool(raw: &str) -> Option<bool> {
        let normalized = raw.trim().to_lowercase();
        if normalized.is_empty() {
            return None;
        }

        match normalized.as_str() {
            "1" | "true" | "yes" | "y" => Some(true),
            "0" | "false" | "no" | "n" => Some(false),
            _ => None,
        }
    }

    let enabled = std::env::var("ENABLE_E2E_TESTS")
        .ok()
        .as_deref()
        .and_then(parse_env_bool)
        == Some(true);

    if !enabled {
        return false;
    }

    can_connect_to_sqlserver()
}

/// Helper functions for E2E tests.
/// Provides utilities to check whether E2E tests can run (connection available).
use super::env::{
    get_mysql_test_dsn, get_oracle_test_dsn, get_postgresql_test_dsn, get_sqlite_test_dsn,
    get_sqlserver_test_dsn, get_sybase_test_dsn, get_test_dsn,
};
use odbc_engine::engine::{OdbcConnection, OdbcEnvironment};
use odbc_engine::test_helpers::load_dotenv;

/// Detected database type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DatabaseType {
    SqlServer,
    Sybase,
    PostgreSQL,
    MySQL,
    Db2,
    Oracle,
    MongoDB,
    SQLite,
    Unknown,
}

/// Detects database type from the connection string.
pub fn detect_database_type(conn_str: &str) -> DatabaseType {
    let conn_lower = conn_str.to_lowercase();

    // Check driver-specific strings first (before generic server= database=).
    if conn_lower.contains("postgresql") {
        return DatabaseType::PostgreSQL;
    }
    if conn_lower.contains("mysql") {
        return DatabaseType::MySQL;
    }
    if conn_lower.contains("db2") || conn_lower.contains("ibm db2") {
        return DatabaseType::Db2;
    }

    // Sybase Anywhere.
    if conn_lower.contains("sql anywhere")
        || conn_lower.contains("sybase")
        || conn_lower.contains("servername=")
    {
        return DatabaseType::Sybase;
    }

    // SQL Server - several possible drivers.
    if conn_lower.contains("sql server")
        || conn_lower.contains("driver={odbc driver")
        || (conn_lower.contains("server=")
            && conn_lower.contains("database=")
            && !conn_lower.contains("sql anywhere"))
    {
        return DatabaseType::SqlServer;
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
/// Uses ODBC_TEST_DSN if set; otherwise ODBC_TEST_DB
/// (postgres|mysql|sqlite|oracle|sybase) or SQL Server defaults.
#[allow(dead_code)]
pub fn get_connection_and_db_type() -> Option<(String, DatabaseType)> {
    load_dotenv();

    if let Some(dsn) = get_test_dsn() {
        return Some((dsn.clone(), detect_database_type(&dsn)));
    }

    let db = std::env::var("ODBC_TEST_DB")
        .ok()
        .as_deref()
        .map(str::to_lowercase);
    let (conn_str, db_type) = match db.as_deref() {
        Some("postgres") | Some("postgresql") => {
            let s = get_postgresql_test_dsn()?;
            (s, DatabaseType::PostgreSQL)
        }
        Some("mysql") => {
            let s = get_mysql_test_dsn()?;
            (s, DatabaseType::MySQL)
        }
        Some("sqlite") => {
            let s = get_sqlite_test_dsn()?;
            (s, DatabaseType::SQLite)
        }
        Some("oracle") => {
            let s = get_oracle_test_dsn()?;
            (s, DatabaseType::Oracle)
        }
        Some("sybase") => {
            let s = get_sybase_test_dsn()?;
            (s, DatabaseType::Sybase)
        }
        _ => {
            let s = get_sqlserver_test_dsn()?;
            (s, DatabaseType::SqlServer)
        }
    };
    Some((conn_str, db_type))
}

/// Checks whether an E2E database connection can be established.
/// Returns `true` when the connection is available and working.
/// Uses ODBC_TEST_DSN, ODBC_TEST_DB, or SQL Server defaults.
#[allow(dead_code)] // Test helper API; used by e2e tests when ODBC is configured
pub fn can_connect_to_sqlserver() -> bool {
    load_dotenv();

    let (conn_str, db_type) = match get_connection_and_db_type() {
        Some(pair) => pair,
        None => return false,
    };

    let env = OdbcEnvironment::new();
    if env.init().is_err() {
        return false;
    }

    let handles = env.get_handles();
    match OdbcConnection::connect(handles, &conn_str) {
        Ok(conn) => {
            let _ = conn.disconnect();
            eprintln!(
                "[OK] Connection successful with {:?} (detected from connection string)",
                db_type
            );
            true
        }
        Err(e) => {
            eprintln!("[ERROR] Connection failed: {:?}", e);
            eprintln!("  Database type: {:?}", db_type);
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

/// Returns SQL to drop a table idempotently (no error if table does not exist).
#[allow(dead_code)]
pub fn sql_drop_table_if_exists(table_name: &str, db_type: DatabaseType) -> String {
    match db_type {
        DatabaseType::SqlServer => {
            format!(
                "IF OBJECT_ID(N'{}', N'U') IS NOT NULL DROP TABLE {}",
                table_name, table_name
            )
        }
        DatabaseType::Oracle => {
            format!(
                "BEGIN EXECUTE IMMEDIATE 'DROP TABLE {}'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;",
                table_name
            )
        }
        _ => format!("DROP TABLE IF EXISTS {}", table_name),
    }
}

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

fn env_flag_enabled(key: &str) -> bool {
    std::env::var(key).ok().as_deref().and_then(parse_env_bool) == Some(true)
}

/// Checks whether E2E tests should run.
/// Runs only when ENABLE_E2E_TESTS is explicitly enabled.
#[allow(dead_code)] // Test helper API; used by e2e tests when ENABLE_E2E_TESTS is set
pub fn should_run_e2e_tests() -> bool {
    // Load variables from .env.
    load_dotenv();

    if !env_flag_enabled("ENABLE_E2E_TESTS") {
        return false;
    }

    can_connect_to_sqlserver()
}

/// Slow / stress / benchmark E2E tests require an extra explicit opt-in on top
/// of the normal E2E gate so `--include-ignored` does not unexpectedly run
/// multi-minute workloads during routine coverage or smoke runs.
#[allow(dead_code)]
pub fn should_run_slow_e2e_tests() -> bool {
    load_dotenv();

    if !should_run_e2e_tests() {
        return false;
    }

    env_flag_enabled("ENABLE_SLOW_E2E_TESTS")
}

/// MSDTC + SQL Server XA smokes require a running DTC and successful
/// `SQL_ATTR_ENLIST_IN_DTC`. Use this opt-in together with
/// `should_run_e2e_tests` so `cargo test --include-ignored` does not fail on
/// machines that have a SQL Server DSN but no working MSDTC enlist path.
#[allow(dead_code)]
pub fn should_run_msdtc_xa_tests() -> bool {
    load_dotenv();
    env_flag_enabled("ENABLE_MSDTC_XA_TESTS")
}

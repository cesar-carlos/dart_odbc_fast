use crate::error::{OdbcError, Result};
use odbc_api::Connection;
use serde::Serialize;

/// Canonical name of a recognised database engine. Stable identifier used
/// for plugin lookup, capability resolution and Dart `DatabaseType` mapping.
pub const ENGINE_SQLSERVER: &str = "sqlserver";
pub const ENGINE_POSTGRES: &str = "postgres";
pub const ENGINE_MYSQL: &str = "mysql";
pub const ENGINE_MARIADB: &str = "mariadb";
pub const ENGINE_ORACLE: &str = "oracle";
pub const ENGINE_SYBASE_ASE: &str = "sybase_ase";
pub const ENGINE_SYBASE_ASA: &str = "sybase_asa";
pub const ENGINE_SQLITE: &str = "sqlite";
pub const ENGINE_DB2: &str = "db2";
pub const ENGINE_SNOWFLAKE: &str = "snowflake";
pub const ENGINE_REDSHIFT: &str = "redshift";
pub const ENGINE_BIGQUERY: &str = "bigquery";
pub const ENGINE_MONGODB: &str = "mongodb";
pub const ENGINE_UNKNOWN: &str = "unknown";

#[derive(Debug, Clone, Serialize)]
pub struct DriverCapabilities {
    pub supports_prepared_statements: bool,
    pub supports_batch_operations: bool,
    pub supports_streaming: bool,
    pub max_row_array_size: u32,
    pub driver_name: String,
    pub driver_version: String,
    /// Canonical engine identifier (one of the `ENGINE_*` constants).
    /// Populated by [`from_driver_name`] / [`detect_from_connection_string`] /
    /// [`detect`]; stable across releases. Defaults to [`ENGINE_UNKNOWN`].
    #[serde(default)]
    pub engine: String,
}

impl DriverCapabilities {
    /// Build capabilities from a driver-name *string*. Accepts:
    /// - canonical engine ids (`"sqlserver"`, `"postgres"`, ...)
    /// - DBMS names returned by `SQLGetInfo(SQL_DBMS_NAME)`
    ///   (`"Microsoft SQL Server"`, `"MariaDB"`, `"Adaptive Server Anywhere"`, ...)
    /// - common ODBC-driver labels (`"PostgreSQL Unicode"`, ...)
    pub fn from_driver_name(driver_name: &str) -> Self {
        let normalized = driver_name.trim().to_lowercase();
        match Self::engine_from_name(&normalized) {
            ENGINE_SQLSERVER => Self::canonical(ENGINE_SQLSERVER, "SQL Server", 2000),
            ENGINE_POSTGRES => Self::canonical(ENGINE_POSTGRES, "PostgreSQL", 2000),
            ENGINE_MYSQL => Self::canonical(ENGINE_MYSQL, "MySQL", 1500),
            ENGINE_MARIADB => Self::canonical(ENGINE_MARIADB, "MariaDB", 1500),
            ENGINE_ORACLE => Self::canonical(ENGINE_ORACLE, "Oracle", 5000),
            ENGINE_SYBASE_ASE => {
                Self::canonical(ENGINE_SYBASE_ASE, "Adaptive Server Enterprise", 1000)
            }
            ENGINE_SYBASE_ASA => Self::canonical(ENGINE_SYBASE_ASA, "SQL Anywhere", 1000),
            ENGINE_SQLITE => Self::canonical(ENGINE_SQLITE, "SQLite", 1000),
            ENGINE_DB2 => Self::canonical(ENGINE_DB2, "IBM Db2", 1000),
            ENGINE_SNOWFLAKE => Self::canonical(ENGINE_SNOWFLAKE, "Snowflake", 1000),
            ENGINE_REDSHIFT => Self::canonical(ENGINE_REDSHIFT, "Amazon Redshift", 1000),
            ENGINE_BIGQUERY => Self::canonical(ENGINE_BIGQUERY, "Google BigQuery", 1000),
            ENGINE_MONGODB => Self::canonical(ENGINE_MONGODB, "MongoDB", 1000),
            _ => Self::default(),
        }
    }

    fn canonical(engine: &str, display: &str, max_array: u32) -> Self {
        Self {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            max_row_array_size: max_array,
            driver_name: display.to_string(),
            driver_version: "Unknown".to_string(),
            engine: engine.to_string(),
        }
    }

    /// Map a *lowercased* substring to a canonical engine id.
    /// Order matters — more specific patterns first.
    fn engine_from_name(lower: &str) -> &'static str {
        // Specific Sybase variants must come before the generic "sybase" fallback.
        if lower.contains("sql anywhere")
            || lower.contains("adaptive server anywhere")
            || lower.contains("asa") && (lower.contains("sybase") || lower.contains("sql anywhere"))
        {
            return ENGINE_SYBASE_ASA;
        }
        if lower.contains("adaptive server enterprise")
            || lower.contains("ase") && (lower.contains("sybase") || lower.contains("adaptive"))
        {
            return ENGINE_SYBASE_ASE;
        }
        if lower.contains("sybase") {
            return ENGINE_SYBASE_ASE;
        }
        // MariaDB needs to win over MySQL because most MariaDB drivers
        // also advertise themselves with "MariaDB" but a fallback could match "mysql".
        if lower.contains("mariadb") {
            return ENGINE_MARIADB;
        }
        if lower.contains("microsoft sql server")
            || lower.contains("sql server")
            || lower.contains("mssql")
            || lower == "sqlserver"
            || lower.contains("sqlsrv32")
        {
            return ENGINE_SQLSERVER;
        }
        if lower.contains("postgresql") || lower.contains("postgres") {
            return ENGINE_POSTGRES;
        }
        if lower.contains("mysql") {
            return ENGINE_MYSQL;
        }
        if lower.contains("oracle") {
            return ENGINE_ORACLE;
        }
        if lower.contains("sqlite") {
            return ENGINE_SQLITE;
        }
        if lower == "db2"
            || lower.contains(" db2")
            || lower.contains("ibm db2")
            || lower.contains("db2/")
        {
            return ENGINE_DB2;
        }
        if lower.contains("snowflake") {
            return ENGINE_SNOWFLAKE;
        }
        if lower.contains("redshift") {
            return ENGINE_REDSHIFT;
        }
        if lower.contains("bigquery") {
            return ENGINE_BIGQUERY;
        }
        if lower.contains("mongodb") {
            return ENGINE_MONGODB;
        }
        ENGINE_UNKNOWN
    }

    /// Heuristic detection from a connection string. Conservative: never
    /// connects, only inspects driver / DSN tokens.
    ///
    /// Use [`detect`] when you have an open connection — it is far more
    /// accurate because it queries the live driver via `SQLGetInfo`.
    pub fn detect_from_connection_string(connection_string: &str) -> Self {
        let lower = connection_string.to_lowercase();
        let engine = Self::engine_from_name(&lower);
        if engine == ENGINE_UNKNOWN {
            return Self::default();
        }
        Self::from_driver_name(engine)
    }

    /// Live detection via `SQLGetInfo(SQL_DBMS_NAME)`. The returned
    /// `driver_name` is the **server-reported** name (e.g.
    /// `"Microsoft SQL Server"`, `"PostgreSQL"`, `"MariaDB"`,
    /// `"Adaptive Server Anywhere"`, `"SQLite"`).
    ///
    /// `engine` is set to the canonical id for plugin lookup.
    pub fn detect(conn: &Connection<'static>) -> Result<Self> {
        let dbms_name = conn
            .database_management_system_name()
            .map_err(OdbcError::from)?;
        let mut caps = Self::from_driver_name(&dbms_name);
        // Always preserve the *exact* DBMS string the server returned,
        // even after `from_driver_name` mapped it to its canonical display label.
        caps.driver_name = dbms_name;
        Ok(caps)
    }

    pub fn to_json(&self) -> Result<String> {
        serde_json::to_string(self).map_err(|error| {
            crate::error::OdbcError::InternalError(format!(
                "Failed to serialize driver capabilities: {}",
                error
            ))
        })
    }
}

impl Default for DriverCapabilities {
    fn default() -> Self {
        Self {
            supports_prepared_statements: true,
            supports_batch_operations: true,
            supports_streaming: true,
            max_row_array_size: 1000,
            driver_name: "Unknown".to_string(),
            driver_version: "Unknown".to_string(),
            engine: ENGINE_UNKNOWN.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_driver_capabilities_default() {
        let caps = DriverCapabilities::default();
        assert!(caps.supports_prepared_statements);
        assert!(caps.supports_batch_operations);
        assert!(caps.supports_streaming);
        assert_eq!(caps.max_row_array_size, 1000);
        assert_eq!(caps.driver_name, "Unknown");
        assert_eq!(caps.driver_version, "Unknown");
        assert_eq!(caps.engine, ENGINE_UNKNOWN);
    }

    #[test]
    fn engine_from_real_dbms_name_microsoft_sql_server() {
        let caps = DriverCapabilities::from_driver_name("Microsoft SQL Server");
        assert_eq!(caps.engine, ENGINE_SQLSERVER);
        assert_eq!(caps.driver_name, "SQL Server");
    }

    #[test]
    fn engine_from_real_dbms_name_mariadb_distinguished_from_mysql() {
        let mariadb = DriverCapabilities::from_driver_name("MariaDB");
        let mysql = DriverCapabilities::from_driver_name("MySQL");
        assert_eq!(mariadb.engine, ENGINE_MARIADB);
        assert_eq!(mysql.engine, ENGINE_MYSQL);
    }

    #[test]
    fn engine_from_real_dbms_name_sybase_variants() {
        let asa = DriverCapabilities::from_driver_name("Adaptive Server Anywhere");
        let ase = DriverCapabilities::from_driver_name("Adaptive Server Enterprise");
        assert_eq!(asa.engine, ENGINE_SYBASE_ASA);
        assert_eq!(ase.engine, ENGINE_SYBASE_ASE);
    }

    #[test]
    fn engine_from_real_dbms_name_db2_snowflake_redshift_bigquery() {
        assert_eq!(
            DriverCapabilities::from_driver_name("IBM Db2").engine,
            ENGINE_DB2
        );
        assert_eq!(
            DriverCapabilities::from_driver_name("Snowflake").engine,
            ENGINE_SNOWFLAKE
        );
        assert_eq!(
            DriverCapabilities::from_driver_name("Amazon Redshift").engine,
            ENGINE_REDSHIFT
        );
        assert_eq!(
            DriverCapabilities::from_driver_name("Google BigQuery").engine,
            ENGINE_BIGQUERY
        );
    }

    #[test]
    fn engine_canonical_ids_round_trip() {
        for engine in [
            ENGINE_SQLSERVER,
            ENGINE_POSTGRES,
            ENGINE_MYSQL,
            ENGINE_MARIADB,
            ENGINE_ORACLE,
            ENGINE_SYBASE_ASE,
            ENGINE_SYBASE_ASA,
            ENGINE_SQLITE,
            ENGINE_DB2,
            ENGINE_SNOWFLAKE,
            ENGINE_REDSHIFT,
            ENGINE_BIGQUERY,
            ENGINE_MONGODB,
        ] {
            let caps = DriverCapabilities::from_driver_name(engine);
            assert_eq!(caps.engine, engine, "round-trip failed for {engine}");
        }
    }

    #[test]
    fn unknown_dbms_name_falls_back_to_default() {
        let caps = DriverCapabilities::from_driver_name("FakeNeverExistsDB");
        assert_eq!(caps.engine, ENGINE_UNKNOWN);
        assert_eq!(caps.driver_name, "Unknown");
    }

    #[test]
    fn test_driver_capabilities_debug() {
        let caps = DriverCapabilities::default();
        let debug_str = format!("{:?}", caps);
        assert!(debug_str.contains("DriverCapabilities"));
    }

    #[test]
    fn test_driver_capabilities_clone() {
        let caps1 = DriverCapabilities::default();
        let caps2 = caps1.clone();
        assert_eq!(
            caps1.supports_prepared_statements,
            caps2.supports_prepared_statements
        );
        assert_eq!(caps1.max_row_array_size, caps2.max_row_array_size);
        assert_eq!(caps1.driver_name, caps2.driver_name);
    }

    #[test]
    fn test_detect_from_connection_string_sqlserver() {
        let caps = DriverCapabilities::detect_from_connection_string(
            "Driver={SQL Server};Server=localhost;Database=test;",
        );
        assert_eq!(caps.driver_name, "SQL Server");
        assert!(caps.supports_prepared_statements);
        assert!(caps.supports_batch_operations);
    }

    #[test]
    fn test_detect_from_connection_string_postgres() {
        let caps = DriverCapabilities::detect_from_connection_string(
            "Driver={PostgreSQL Unicode};Server=localhost;Database=test;",
        );
        assert_eq!(caps.driver_name, "PostgreSQL");
        assert!(caps.supports_streaming);
    }

    #[test]
    fn test_detect_from_connection_string_mysql() {
        let caps = DriverCapabilities::detect_from_connection_string(
            "Driver={MySQL ODBC 8.0 Driver};Server=localhost;Database=test;",
        );
        assert_eq!(caps.driver_name, "MySQL");
        assert!(caps.supports_streaming);
    }

    #[test]
    fn test_detect_from_connection_string_unknown() {
        let caps = DriverCapabilities::detect_from_connection_string(
            "Driver={UnknownDriver};Server=localhost;",
        );
        assert_eq!(caps.driver_name, "Unknown");
        assert_eq!(caps.engine, ENGINE_UNKNOWN);
    }

    #[test]
    fn detect_from_connection_string_recognises_new_engines() {
        let cases = [
            ("Driver={IBM DB2 ODBC};Database=test;", ENGINE_DB2),
            (
                "Driver={Snowflake};Server=acct.snowflakecomputing.com;",
                ENGINE_SNOWFLAKE,
            ),
            ("Driver={Amazon Redshift x64};Server=h;", ENGINE_REDSHIFT),
            (
                "Driver={Simba ODBC Driver for Google BigQuery};Project=p;",
                ENGINE_BIGQUERY,
            ),
            (
                "Driver={MariaDB ODBC 3.1 Driver};Server=h;Database=d;",
                ENGINE_MARIADB,
            ),
        ];
        for (cs, expected) in cases {
            let caps = DriverCapabilities::detect_from_connection_string(cs);
            assert_eq!(caps.engine, expected, "failed for connection string: {cs}");
        }
    }

    #[test]
    fn test_driver_capabilities_to_json() {
        let caps = DriverCapabilities::from_driver_name("postgres");
        let payload = caps.to_json().expect("json payload");
        assert!(payload.contains("\"driver_name\":\"PostgreSQL\""));
        assert!(payload.contains("\"supports_prepared_statements\":true"));
    }
}

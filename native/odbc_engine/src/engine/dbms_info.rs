//! Live DBMS introspection via ODBC `SQLGetInfo` (NEW in v2.1).
//!
//! Whereas [`engine::core::DriverCapabilities::detect_from_connection_string`]
//! is a heuristic over the **connection string**, this module talks to the
//! live driver and asks the server who it is.
//!
//! The result is more accurate in three important cases:
//! - DSN-only connection strings (`DSN=mydsn;UID=x;PWD=y`) where no `Driver=`
//!   token is present.
//! - Custom / vendor-specific drivers (Devart, DataDirect, ...) whose names
//!   do not match the heuristic patterns.
//! - Distinguishing **MariaDB** from **MySQL**, **Adaptive Server Anywhere**
//!   from **Adaptive Server Enterprise**, etc.

use crate::engine::core::DriverCapabilities;
use crate::error::{OdbcError, Result};
use crate::handles::{CachedConnection, SharedHandleManager};
use odbc_api::Connection;
use serde::Serialize;

/// Snapshot of `SQLGetInfo` properties relevant to a Dart consumer.
///
/// Identification fields (`dbms_name`, `dbms_version`, `engine`) come from
/// live `SQLGetInfo`. Nested [`DriverCapabilities`] boolean flags and
/// `max_row_array_size` remain a canonical table per engine; live
/// `driver_name` / `driver_version` are `SQL_DRIVER_NAME` / `SQL_DRIVER_VER`.
#[derive(Debug, Clone, Serialize)]
pub struct DbmsInfo {
    /// `SQL_DBMS_NAME` — server-reported product name
    /// (e.g. `"Microsoft SQL Server"`, `"PostgreSQL"`, `"MariaDB"`).
    pub dbms_name: String,
    /// `SQL_DBMS_VER` — server-reported product version (empty when unknown).
    #[serde(default)]
    pub dbms_version: String,
    /// Canonical engine identifier (one of `engine::core::ENGINE_*`).
    pub engine: String,
    /// Maximum length of a catalog identifier (0 if unknown).
    pub max_catalog_name_len: u32,
    /// Maximum length of a schema identifier (0 if unknown).
    pub max_schema_name_len: u32,
    /// Maximum length of a table identifier (0 if unknown).
    pub max_table_name_len: u32,
    /// Maximum length of a column identifier (0 if unknown).
    pub max_column_name_len: u32,
    /// Currently selected catalog/database (empty when not applicable).
    pub current_catalog: String,
    /// Capabilities derived from the DBMS name (same struct returned by
    /// `odbc_get_driver_capabilities`).
    pub capabilities: DriverCapabilities,
}

/// Resolve only the canonical engine id from `SQL_DBMS_NAME`.
///
/// Prefer this over [`DbmsInfo::detect`] on hot paths (transaction begin)
/// that do not need identifier-length limits or the current catalog —
/// those require extra `SQLGetInfo` round-trips.
pub fn detect_engine_id(conn: &Connection<'static>) -> Result<&'static str> {
    let dbms_name = conn
        .database_management_system_name()
        .map_err(OdbcError::from)?;
    Ok(DriverCapabilities::canonical_engine_id(&dbms_name))
}

impl DbmsInfo {
    /// Query the live connection and assemble a [`DbmsInfo`] snapshot.
    /// All `max_*_name_len` and version calls are best-effort: if the driver
    /// fails, length fields stay at `0`, version strings stay empty /
    /// `"Unknown"`, and the overall call still succeeds when `SQL_DBMS_NAME`
    /// is available.
    pub fn detect(conn: &Connection<'static>) -> Result<Self> {
        Self::detect_with_engine(conn, None)
    }

    /// Like [`Self::detect`], using a pre-resolved canonical engine id
    /// (typically [`CachedConnection::engine_id`]) so the `OnceLock` stays
    /// warm for XA / transaction / plugin lookup.
    pub fn detect_from_cached(cached: &CachedConnection) -> Result<Self> {
        let engine = cached.engine_id()?;
        Self::detect_with_engine(cached.connection(), Some(engine))
    }

    fn detect_with_engine(
        conn: &Connection<'static>,
        engine_id: Option<&'static str>,
    ) -> Result<Self> {
        let dbms_name = conn
            .database_management_system_name()
            .map_err(OdbcError::from)?;

        let engine = engine_id
            .unwrap_or_else(|| DriverCapabilities::canonical_engine_id(&dbms_name))
            .to_string();

        let capabilities = DriverCapabilities::detect(conn)?;
        let dbms_version = crate::engine::odbc_get_info::dbms_ver(conn).unwrap_or_default();

        let max_catalog_name_len = conn.max_catalog_name_len().map(u32::from).unwrap_or(0);
        let max_schema_name_len = conn.max_schema_name_len().map(u32::from).unwrap_or(0);
        let max_table_name_len = conn.max_table_name_len().map(u32::from).unwrap_or(0);
        let max_column_name_len = conn.max_column_name_len().map(u32::from).unwrap_or(0);
        let current_catalog = conn.current_catalog().unwrap_or_default();

        Ok(Self {
            engine,
            dbms_name,
            dbms_version,
            max_catalog_name_len,
            max_schema_name_len,
            max_table_name_len,
            max_column_name_len,
            current_catalog,
            capabilities,
        })
    }

    /// Convenience: query a connection by id through the shared handle manager.
    pub fn detect_for_conn_id(handles: &SharedHandleManager, conn_id: u32) -> Result<Self> {
        let conn_arc = {
            let h = crate::error::lock_mutex(handles.as_ref())?;
            h.get_connection(conn_id)?
        };
        let cached = crate::error::lock_mutex(conn_arc.as_ref())?;
        Self::detect_from_cached(&cached)
    }

    pub fn to_json(&self) -> Result<String> {
        serde_json::to_string(self)
            .map_err(|e| OdbcError::InternalError(format!("Failed to serialize DbmsInfo: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::core::{
        ENGINE_DB2, ENGINE_MARIADB, ENGINE_MYSQL, ENGINE_ORACLE, ENGINE_POSTGRES, ENGINE_SNOWFLAKE,
        ENGINE_SQLITE, ENGINE_SQLSERVER, ENGINE_UNKNOWN,
    };

    fn fake(dbms_name: &str) -> DbmsInfo {
        let caps = DriverCapabilities::from_driver_name(dbms_name);
        DbmsInfo {
            engine: caps.engine.clone(),
            dbms_name: dbms_name.to_string(),
            dbms_version: "15.0".to_string(),
            max_catalog_name_len: 128,
            max_schema_name_len: 128,
            max_table_name_len: 128,
            max_column_name_len: 128,
            current_catalog: "main".to_string(),
            capabilities: caps,
        }
    }

    #[test]
    fn canonical_engine_id_matches_from_driver_name() {
        assert_eq!(
            DriverCapabilities::canonical_engine_id("Microsoft SQL Server"),
            ENGINE_SQLSERVER
        );
        assert_eq!(
            DriverCapabilities::canonical_engine_id("PostgreSQL"),
            ENGINE_POSTGRES
        );
        assert_eq!(
            DriverCapabilities::canonical_engine_id("MariaDB"),
            ENGINE_MARIADB
        );
        assert_eq!(
            DriverCapabilities::canonical_engine_id("FantasyDB"),
            ENGINE_UNKNOWN
        );
    }

    #[test]
    fn dbms_info_engine_matches_capabilities() {
        let info = fake("Microsoft SQL Server");
        assert_eq!(info.engine, ENGINE_SQLSERVER);
        assert_eq!(info.capabilities.engine, ENGINE_SQLSERVER);
    }

    #[test]
    fn dbms_info_distinguishes_mariadb_from_mysql() {
        assert_eq!(fake("MariaDB").engine, ENGINE_MARIADB);
        assert_eq!(fake("MySQL").engine, ENGINE_MYSQL);
    }

    #[test]
    fn dbms_info_postgres_canonical() {
        assert_eq!(fake("PostgreSQL").engine, ENGINE_POSTGRES);
    }

    #[test]
    fn dbms_info_unknown_engine_falls_back() {
        let info = fake("FantasyDB");
        assert_eq!(info.engine, ENGINE_UNKNOWN);
        assert_eq!(info.dbms_name, "FantasyDB");
    }

    #[test]
    fn dbms_info_oracle_sqlite_snowflake_and_db2() {
        assert_eq!(fake("Oracle Database").engine, ENGINE_ORACLE);
        assert_eq!(fake("SQLite").engine, ENGINE_SQLITE);
        assert_eq!(fake("Snowflake").engine, ENGINE_SNOWFLAKE);
        assert_eq!(fake("IBM Db2").engine, ENGINE_DB2);
    }

    #[test]
    fn dbms_info_serializes_to_json_with_engine_field() {
        let info = fake("PostgreSQL");
        let json = info.to_json().expect("json");
        assert!(json.contains("\"dbms_name\":\"PostgreSQL\""));
        assert!(json.contains("\"engine\":\"postgres\""));
        assert!(json.contains("\"dbms_version\":\"15.0\""));
        assert!(json.contains("\"current_catalog\":\"main\""));
    }

    #[test]
    fn dbms_info_json_includes_max_name_lengths() {
        let json = fake("MySQL").to_json().expect("json");
        assert!(json.contains("\"max_catalog_name_len\":128"));
        assert!(json.contains("\"max_column_name_len\":128"));
    }

    #[test]
    fn dbms_info_maps_sybase_ase_and_redshift_engines() {
        use crate::engine::core::{ENGINE_REDSHIFT, ENGINE_SYBASE_ASE};

        assert_eq!(fake("Adaptive Server Enterprise").engine, ENGINE_SYBASE_ASE);
        assert_eq!(fake("Amazon Redshift").engine, ENGINE_REDSHIFT);
    }

    #[test]
    fn dbms_info_clone_preserves_dbms_name_and_engine() {
        let info = fake("PostgreSQL");
        let cloned = info.clone();
        assert_eq!(cloned.dbms_name, info.dbms_name);
        assert_eq!(cloned.engine, info.engine);
        assert_eq!(cloned.current_catalog, info.current_catalog);
    }

    #[test]
    fn dbms_info_debug_includes_dbms_name() {
        let info = fake("SQLite");
        let debug = format!("{info:?}");
        assert!(debug.contains("SQLite"));
    }
}

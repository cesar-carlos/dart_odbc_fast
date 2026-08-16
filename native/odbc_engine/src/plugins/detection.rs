//! Driver detection helpers for the plugin registry.
//!
//! Keeps connection-string and DBMS-name resolution separate from plugin
//! registration and dispatch so `registry.rs` stays focused on lookup.

use crate::engine::core::{
    DriverCapabilities, ENGINE_DB2, ENGINE_MARIADB, ENGINE_MYSQL, ENGINE_ORACLE, ENGINE_POSTGRES,
    ENGINE_SNOWFLAKE, ENGINE_SQLITE, ENGINE_SQLSERVER, ENGINE_SYBASE_ASA, ENGINE_SYBASE_ASE,
};

/// Map a server-reported DBMS name (`SQL_DBMS_NAME`) to the *registry*
/// plugin id (`"sqlserver"`, `"postgres"`, `"mariadb"`, ...). Returns
/// `None` for unknown engines (and for engines without a dedicated plugin).
pub fn plugin_id_for_dbms_name(dbms_name: &str) -> Option<&'static str> {
    let caps = DriverCapabilities::from_driver_name(dbms_name);
    match caps.engine.as_str() {
        ENGINE_SQLSERVER => Some("sqlserver"),
        ENGINE_POSTGRES => Some("postgres"),
        ENGINE_MYSQL => Some("mysql"),
        ENGINE_MARIADB => Some("mariadb"),
        ENGINE_ORACLE => Some("oracle"),
        ENGINE_SYBASE_ASE | ENGINE_SYBASE_ASA => Some("sybase"),
        ENGINE_SQLITE => Some("sqlite"),
        ENGINE_DB2 => Some("db2"),
        ENGINE_SNOWFLAKE => Some("snowflake"),
        _ => None,
    }
}

/// Resolve the registry plugin id from a connection string.
///
/// Reuses the canonical engine detection from [`DriverCapabilities`].
pub fn plugin_id_from_connection_string(connection_string: &str) -> Option<String> {
    let caps = DriverCapabilities::detect_from_connection_string(connection_string);
    if caps.engine == crate::engine::core::ENGINE_UNKNOWN {
        return None;
    }
    plugin_id_for_dbms_name(&caps.driver_name)
        .or(Some(caps.engine.as_str()))
        .map(|s| s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plugin_id_for_sqlserver_dbms_name() {
        assert_eq!(
            plugin_id_for_dbms_name("Microsoft SQL Server"),
            Some("sqlserver")
        );
    }

    #[test]
    fn plugin_id_from_postgres_connection_string() {
        let id = plugin_id_from_connection_string("Driver={PostgreSQL};Server=localhost;");
        assert_eq!(id.as_deref(), Some("postgres"));
    }

    #[test]
    fn plugin_id_from_connection_string_ignores_uid_and_dsn_only() {
        assert_eq!(
            plugin_id_from_connection_string("Driver={MySQL ODBC};UID=postgres;"),
            Some("mysql".to_string())
        );
        assert_eq!(
            plugin_id_from_connection_string("DSN=prod;UID=postgres;PWD=x"),
            None
        );
    }

    #[test]
    fn plugin_id_for_mariadb_sybase_and_unknown_dbms_names() {
        assert_eq!(plugin_id_for_dbms_name("MariaDB"), Some("mariadb"));
        assert_eq!(
            plugin_id_for_dbms_name("Adaptive Server Anywhere"),
            Some("sybase")
        );
        assert_eq!(plugin_id_for_dbms_name("FantasyDB"), None);
        assert_eq!(plugin_id_for_dbms_name("Amazon Redshift"), None);
    }
}

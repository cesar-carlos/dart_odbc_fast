use super::driver_plugin::DriverPlugin;
use crate::engine::core::{
    DriverCapabilities, ENGINE_DB2, ENGINE_MARIADB, ENGINE_MYSQL, ENGINE_ORACLE, ENGINE_POSTGRES,
    ENGINE_SNOWFLAKE, ENGINE_SQLITE, ENGINE_SQLSERVER, ENGINE_SYBASE_ASA, ENGINE_SYBASE_ASE,
};
use crate::error::{OdbcError, Result};
use odbc_api::Connection;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

pub struct PluginRegistry {
    plugins: Arc<Mutex<HashMap<String, Arc<dyn DriverPlugin>>>>,
}

impl PluginRegistry {
    pub fn new() -> Self {
        Self {
            plugins: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn register(&self, plugin: Arc<dyn DriverPlugin>) -> Result<()> {
        let mut plugins = self
            .plugins
            .lock()
            .map_err(|_| OdbcError::InternalError("Lock poisoned".to_string()))?;
        plugins.insert(plugin.name().to_string(), plugin);
        Ok(())
    }

    pub fn get(&self, driver_name: &str) -> Result<Arc<dyn DriverPlugin>> {
        let plugins = self
            .plugins
            .lock()
            .map_err(|_| OdbcError::InternalError("Lock poisoned".to_string()))?;
        plugins
            .get(driver_name)
            .cloned()
            .ok_or_else(|| OdbcError::InternalError(format!("Plugin not found: {}", driver_name)))
    }

    pub fn detect_driver(&self, connection_string: &str) -> Option<String> {
        // Reuse the canonical engine detection from `DriverCapabilities`.
        let caps = DriverCapabilities::detect_from_connection_string(connection_string);
        if caps.engine == crate::engine::core::ENGINE_UNKNOWN {
            return None;
        }
        // Map to the registry plugin id (mariadb falls back to mysql when the
        // dedicated plugin isn't registered; both are by default in v3.0).
        Self::plugin_id_for_dbms_name(&caps.driver_name)
            .or(Some(caps.engine.as_str()))
            .map(|s| s.to_string())
    }

    pub fn get_for_connection(&self, connection_string: &str) -> Option<Arc<dyn DriverPlugin>> {
        let driver_name = self.detect_driver(connection_string)?;
        match self.get(&driver_name) {
            Ok(p) => Some(p),
            Err(_) => {
                // A7 fix: surface the gap explicitly instead of returning None silently.
                // `detect_driver` may know a name (e.g. "mongodb", "sqlite") for which
                // no plugin is currently registered. Caller falls back to defaults.
                log::warn!(
                    "Detected driver '{driver_name}' has no registered plugin; \
                     using default behaviour (no driver-specific optimisations)"
                );
                None
            }
        }
    }

    /// Returns true when [`detect_driver`] would yield a name that is also
    /// registered. Useful to expose driver-support introspection to callers.
    pub fn is_supported(&self, connection_string: &str) -> bool {
        let Some(name) = self.detect_driver(connection_string) else {
            return false;
        };
        self.get(&name).is_ok()
    }

    /// Map a server-reported DBMS name (`SQL_DBMS_NAME`) to the *registry*
    /// plugin id (`"sqlserver"`, `"postgres"`, ...). MariaDB falls back to
    /// the MySQL plugin since they share the wire protocol and most ODBC
    /// optimisations.  Returns `None` for unknown engines.
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

    /// Resolve the plugin from a server-reported DBMS name.
    /// Pairs with `Connection::dbms_info()` for accurate live detection.
    pub fn get_for_dbms_name(&self, dbms_name: &str) -> Option<Arc<dyn DriverPlugin>> {
        let id = Self::plugin_id_for_dbms_name(dbms_name)?;
        self.get(id).ok()
    }

    /// Build the dialect-specific UPSERT SQL for a connection-string-resolved
    /// plugin. Returns `None` when no plugin matches.
    pub fn build_upsert_sql(
        &self,
        connection_string: &str,
        table: &str,
        columns: &[&str],
        conflict_columns: &[&str],
        update_columns: Option<&[&str]>,
    ) -> Option<Result<String>> {
        // Map plugin name → upsert builder. Keeps the registry SOLID without
        // requiring `Any` downcasting (each plugin already implements
        // `Upsertable` directly in its module).
        let driver = self.detect_driver(connection_string)?;
        Some(self.dispatch_upsert(&driver, table, columns, conflict_columns, update_columns))
    }

    fn dispatch_upsert(
        &self,
        plugin_id: &str,
        table: &str,
        columns: &[&str],
        conflict_columns: &[&str],
        update_columns: Option<&[&str]>,
    ) -> Result<String> {
        use super::capabilities::Upsertable;
        match plugin_id {
            "sqlserver" => super::sqlserver::SqlServerPlugin::new().build_upsert_sql(
                table,
                columns,
                conflict_columns,
                update_columns,
            ),
            "postgres" => super::postgres::PostgresPlugin::new().build_upsert_sql(
                table,
                columns,
                conflict_columns,
                update_columns,
            ),
            "mysql" => super::mysql::MySqlPlugin::new().build_upsert_sql(
                table,
                columns,
                conflict_columns,
                update_columns,
            ),
            "mariadb" => super::mariadb::MariaDbPlugin::new().build_upsert_sql(
                table,
                columns,
                conflict_columns,
                update_columns,
            ),
            "oracle" => super::oracle::OraclePlugin::new().build_upsert_sql(
                table,
                columns,
                conflict_columns,
                update_columns,
            ),
            "sybase" => super::sybase::SybasePlugin::new().build_upsert_sql(
                table,
                columns,
                conflict_columns,
                update_columns,
            ),
            "sqlite" => super::sqlite::SqlitePlugin::new().build_upsert_sql(
                table,
                columns,
                conflict_columns,
                update_columns,
            ),
            "db2" => super::db2::Db2Plugin::new().build_upsert_sql(
                table,
                columns,
                conflict_columns,
                update_columns,
            ),
            "snowflake" => super::snowflake::SnowflakePlugin::new().build_upsert_sql(
                table,
                columns,
                conflict_columns,
                update_columns,
            ),
            _ => Err(crate::error::OdbcError::UnsupportedFeature(format!(
                "No UPSERT support for plugin {plugin_id:?}"
            ))),
        }
    }

    /// Build a RETURNING/OUTPUT clause appended to `sql` for the connection's plugin.
    pub fn append_returning_sql(
        &self,
        connection_string: &str,
        sql: &str,
        verb: super::capabilities::returning::DmlVerb,
        columns: &[&str],
    ) -> Option<Result<String>> {
        let driver = self.detect_driver(connection_string)?;
        Some(self.dispatch_returning(&driver, sql, verb, columns))
    }

    fn dispatch_returning(
        &self,
        plugin_id: &str,
        sql: &str,
        verb: super::capabilities::returning::DmlVerb,
        columns: &[&str],
    ) -> Result<String> {
        use super::capabilities::Returnable;
        match plugin_id {
            "sqlserver" => {
                super::sqlserver::SqlServerPlugin::new().append_returning_clause(sql, verb, columns)
            }
            "postgres" => {
                super::postgres::PostgresPlugin::new().append_returning_clause(sql, verb, columns)
            }
            "mysql" => super::mysql::MySqlPlugin::new().append_returning_clause(sql, verb, columns),
            "mariadb" => {
                super::mariadb::MariaDbPlugin::new().append_returning_clause(sql, verb, columns)
            }
            "oracle" => {
                super::oracle::OraclePlugin::new().append_returning_clause(sql, verb, columns)
            }
            "sybase" => {
                super::sybase::SybasePlugin::new().append_returning_clause(sql, verb, columns)
            }
            "sqlite" => {
                super::sqlite::SqlitePlugin::new().append_returning_clause(sql, verb, columns)
            }
            "db2" => super::db2::Db2Plugin::new().append_returning_clause(sql, verb, columns),
            "snowflake" => {
                super::snowflake::SnowflakePlugin::new().append_returning_clause(sql, verb, columns)
            }
            _ => Err(crate::error::OdbcError::UnsupportedFeature(format!(
                "No RETURNING support for plugin {plugin_id:?}"
            ))),
        }
    }

    /// Get the post-connect setup statements for the plugin matching
    /// `connection_string`, customised by `opts`.
    pub fn session_init_sql(
        &self,
        connection_string: &str,
        opts: &super::capabilities::SessionOptions,
    ) -> Option<Vec<String>> {
        use super::capabilities::SessionInitializer;
        let driver = self.detect_driver(connection_string)?;
        Some(match driver.as_str() {
            "sqlserver" => super::sqlserver::SqlServerPlugin::new().initialization_sql(opts),
            "postgres" => super::postgres::PostgresPlugin::new().initialization_sql(opts),
            "mysql" => super::mysql::MySqlPlugin::new().initialization_sql(opts),
            "mariadb" => super::mariadb::MariaDbPlugin::new().initialization_sql(opts),
            "oracle" => super::oracle::OraclePlugin::new().initialization_sql(opts),
            "sybase" => super::sybase::SybasePlugin::new().initialization_sql(opts),
            "sqlite" => super::sqlite::SqlitePlugin::new().initialization_sql(opts),
            "db2" => super::db2::Db2Plugin::new().initialization_sql(opts),
            "snowflake" => super::snowflake::SnowflakePlugin::new().initialization_sql(opts),
            _ => Vec::new(),
        })
    }

    /// Resolve the plugin from a live ODBC connection by issuing
    /// `SQLGetInfo(SQL_DBMS_NAME)`. This is the most accurate path because
    /// it bypasses connection-string parsing entirely.
    pub fn get_for_live_connection(
        &self,
        conn: &Connection<'static>,
    ) -> Option<Arc<dyn DriverPlugin>> {
        match conn.database_management_system_name() {
            Ok(name) => self.get_for_dbms_name(&name),
            Err(e) => {
                log::warn!("PluginRegistry::get_for_live_connection: SQLGetInfo failed: {e}");
                None
            }
        }
    }
}

impl Default for PluginRegistry {
    fn default() -> Self {
        let registry = Self::new();

        // M15: log (don't swallow) registration failures. The Mutex would only fail
        // if poisoned during construction — extremely unlikely here, but visible
        // when it happens.
        for plugin in [
            Arc::new(super::sqlserver::SqlServerPlugin::new()) as Arc<dyn DriverPlugin>,
            Arc::new(super::oracle::OraclePlugin::new()) as Arc<dyn DriverPlugin>,
            Arc::new(super::postgres::PostgresPlugin::new()) as Arc<dyn DriverPlugin>,
            Arc::new(super::mysql::MySqlPlugin::new()) as Arc<dyn DriverPlugin>,
            Arc::new(super::mariadb::MariaDbPlugin::new()) as Arc<dyn DriverPlugin>,
            Arc::new(super::sybase::SybasePlugin::new()) as Arc<dyn DriverPlugin>,
            Arc::new(super::sqlite::SqlitePlugin::new()) as Arc<dyn DriverPlugin>,
            Arc::new(super::db2::Db2Plugin::new()) as Arc<dyn DriverPlugin>,
            Arc::new(super::snowflake::SnowflakePlugin::new()) as Arc<dyn DriverPlugin>,
        ] {
            let name = plugin.name().to_string();
            if let Err(e) = registry.register(plugin) {
                log::error!("PluginRegistry::default: failed to register {name}: {e}");
            }
        }

        registry
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::types::OdbcType;

    #[test]
    fn test_get_for_connection_sqlserver() {
        let registry = PluginRegistry::default();
        let conn_str = "Driver={SQL Server};Server=localhost;Database=test;";
        let plugin = registry.get_for_connection(conn_str).expect("plugin");
        assert_eq!(plugin.name(), "sqlserver");
    }

    #[test]
    fn test_get_for_connection_sybase() {
        let registry = PluginRegistry::default();
        let conn_str = "Driver={Sybase ASE};Server=localhost;";
        let plugin = registry.get_for_connection(conn_str).expect("plugin");
        assert_eq!(plugin.name(), "sybase");
    }

    #[test]
    fn test_get_for_connection_sql_anywhere() {
        let registry = PluginRegistry::default();
        let conn_str = "Driver={SQL Anywhere 16};Host=localhost;Port=2650;";
        let plugin = registry.get_for_connection(conn_str).expect("plugin");
        assert_eq!(plugin.name(), "sybase");
    }

    #[test]
    fn test_get_for_connection_unknown_driver() {
        let registry = PluginRegistry::default();
        let conn_str = "Driver={UnknownDriver};Server=localhost;";
        assert!(registry.get_for_connection(conn_str).is_none());
    }

    #[test]
    fn test_detect_driver_mysql() {
        let registry = PluginRegistry::default();
        assert_eq!(
            registry.detect_driver("Driver={MySQL};Server=localhost;"),
            Some("mysql".to_string())
        );
        assert_eq!(
            registry.detect_driver("DRIVER={MySQL ODBC 8.0 Driver};"),
            Some("mysql".to_string())
        );
    }

    #[test]
    fn test_detect_driver_mongodb() {
        let registry = PluginRegistry::default();
        assert_eq!(
            registry.detect_driver("Driver={MongoDB ODBC};Server=localhost;"),
            Some("mongodb".to_string())
        );
    }

    #[test]
    fn test_detect_driver_sqlite() {
        let registry = PluginRegistry::default();
        assert_eq!(
            registry.detect_driver("Driver=SQLite3 ODBC Driver;Database=test.db;"),
            Some("sqlite".to_string())
        );
    }

    #[test]
    fn test_default_registry_has_all_plugins() {
        let registry = PluginRegistry::default();
        assert!(registry.get("sqlserver").is_ok());
        assert!(registry.get("oracle").is_ok());
        assert!(registry.get("postgres").is_ok());
        assert!(registry.get("mysql").is_ok());
        assert!(registry.get("sybase").is_ok());
    }

    #[test]
    fn test_detect_driver_case_insensitive() {
        let registry = PluginRegistry::default();
        let p1 = registry.get_for_connection("DRIVER={SQL SERVER};SERVER=localhost;");
        let p2 = registry.get_for_connection("driver={sql server};server=localhost;");
        assert!(p1.is_some());
        assert!(p2.is_some());
        assert_eq!(p1.unwrap().name(), "sqlserver");
        assert_eq!(p2.unwrap().name(), "sqlserver");
    }

    #[test]
    fn test_get_plugin_not_found() {
        let registry = PluginRegistry::default();
        let result = registry.get("nonexistent");
        assert!(result.is_err());
    }

    #[test]
    fn test_get_for_connection_postgres() {
        let registry = PluginRegistry::default();
        let conn_str = "Driver={PostgreSQL Unicode};Server=localhost;Database=test;";
        let plugin = registry.get_for_connection(conn_str).expect("plugin");
        assert_eq!(plugin.name(), "postgres");
    }

    #[test]
    fn test_get_for_connection_postgresql() {
        let registry = PluginRegistry::default();
        let conn_str = "Driver={PostgreSQL ODBC Driver};Server=localhost;";
        let plugin = registry.get_for_connection(conn_str).expect("plugin");
        assert_eq!(plugin.name(), "postgres");
    }

    #[test]
    fn test_get_for_connection_mysql() {
        let registry = PluginRegistry::default();
        let conn_str = "Driver={MySQL ODBC 8.0 Driver};Server=localhost;";
        let plugin = registry.get_for_connection(conn_str).expect("plugin");
        assert_eq!(plugin.name(), "mysql");
    }

    #[test]
    fn test_detect_driver_postgres() {
        let registry = PluginRegistry::default();
        assert_eq!(
            registry.detect_driver("Driver={PostgreSQL};Server=localhost;"),
            Some("postgres".to_string())
        );
        assert_eq!(
            registry.detect_driver("DRIVER={PostgreSQL ODBC Driver};"),
            Some("postgres".to_string())
        );
    }

    #[test]
    fn test_postgres_plugin_capabilities_via_registry() {
        let registry = PluginRegistry::default();
        let plugin = registry.get("postgres").expect("postgres plugin");
        let caps = plugin.get_capabilities();

        assert!(caps.supports_prepared_statements);
        assert!(caps.supports_batch_operations);
        assert!(caps.supports_streaming);
        assert_eq!(caps.driver_name, "PostgreSQL");
    }

    #[test]
    fn test_mysql_plugin_capabilities_via_registry() {
        let registry = PluginRegistry::default();
        let plugin = registry.get("mysql").expect("mysql plugin");
        let caps = plugin.get_capabilities();

        assert!(caps.supports_prepared_statements);
        assert!(caps.supports_batch_operations);
        assert!(caps.supports_streaming);
        assert_eq!(caps.driver_name, "MySQL");
    }

    #[test]
    fn test_postgres_plugin_optimize_query() {
        let registry = PluginRegistry::default();
        let plugin = registry.get("postgres").expect("postgres plugin");

        let sql = "SELECT * FROM users";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 1000");
    }

    #[test]
    fn test_mysql_plugin_optimize_query() {
        let registry = PluginRegistry::default();
        let plugin = registry.get("mysql").expect("mysql plugin");

        let sql = "SELECT * FROM users";
        let optimized = plugin.optimize_query(sql);
        assert_eq!(optimized, "SELECT * FROM users LIMIT 1000");
    }

    #[test]
    fn test_postgres_plugin_map_type_via_registry() {
        let registry = PluginRegistry::default();
        let plugin = registry.get("postgres").expect("postgres plugin");

        assert_eq!(plugin.map_type(1), OdbcType::Varchar);
        assert_eq!(plugin.map_type(4), OdbcType::Integer);
        assert_eq!(plugin.map_type(-5), OdbcType::BigInt);
    }

    #[test]
    fn test_mysql_plugin_map_type_via_registry() {
        let registry = PluginRegistry::default();
        let plugin = registry.get("mysql").expect("mysql plugin");

        assert_eq!(plugin.map_type(1), OdbcType::Varchar);
        assert_eq!(plugin.map_type(4), OdbcType::Integer);
        assert_eq!(plugin.map_type(-5), OdbcType::BigInt);
    }
}

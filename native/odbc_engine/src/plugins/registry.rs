use super::detection::{plugin_id_for_dbms_name, plugin_id_from_connection_string};
use super::driver_plugin::DriverPlugin;
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
        let mut plugins = crate::error::lock_mutex(self.plugins.as_ref())?;
        plugins.insert(plugin.name().to_string(), plugin);
        Ok(())
    }

    pub fn get(&self, driver_name: &str) -> Result<Arc<dyn DriverPlugin>> {
        let plugins = crate::error::lock_mutex(self.plugins.as_ref())?;
        plugins
            .get(driver_name)
            .cloned()
            .ok_or_else(|| OdbcError::InternalError(format!("Plugin not found: {}", driver_name)))
    }

    pub fn detect_driver(&self, connection_string: &str) -> Option<String> {
        plugin_id_from_connection_string(connection_string)
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

    /// Map a server-reported DBMS name (`SQL_DBMS_NAME`) to the registry plugin id.
    pub fn plugin_id_for_dbms_name(dbms_name: &str) -> Option<&'static str> {
        plugin_id_for_dbms_name(dbms_name)
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
#[path = "registry/tests.rs"]
mod tests;

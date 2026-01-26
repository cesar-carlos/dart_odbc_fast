use super::driver_plugin::DriverPlugin;
use crate::error::{OdbcError, Result};
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
        let lower = connection_string.to_lowercase();

        if lower.contains("sql server") || lower.contains("mssql") || lower.contains("sqlserver") {
            return Some("sqlserver".to_string());
        }
        if lower.contains("oracle") {
            return Some("oracle".to_string());
        }
        if lower.contains("postgres") || lower.contains("postgresql") {
            return Some("postgres".to_string());
        }
        if lower.contains("sybase") || lower.contains("sql anywhere") {
            return Some("sybase".to_string());
        }

        None
    }

    pub fn get_for_connection(&self, connection_string: &str) -> Option<Arc<dyn DriverPlugin>> {
        if let Some(driver_name) = self.detect_driver(connection_string) {
            self.get(&driver_name).ok()
        } else {
            None
        }
    }
}

impl Default for PluginRegistry {
    fn default() -> Self {
        let registry = Self::new();

        registry
            .register(Arc::new(super::sqlserver::SqlServerPlugin::new()))
            .unwrap_or_default();
        registry
            .register(Arc::new(super::oracle::OraclePlugin::new()))
            .unwrap_or_default();
        registry
            .register(Arc::new(super::postgres::PostgresPlugin::new()))
            .unwrap_or_default();
        registry
            .register(Arc::new(super::sybase::SybasePlugin::new()))
            .unwrap_or_default();

        registry
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let conn_str = "Driver={MySQL};Server=localhost;";
        assert!(registry.get_for_connection(conn_str).is_none());
    }

    #[test]
    fn test_default_registry_has_all_plugins() {
        let registry = PluginRegistry::default();
        assert!(registry.get("sqlserver").is_ok());
        assert!(registry.get("oracle").is_ok());
        assert!(registry.get("postgres").is_ok());
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
}

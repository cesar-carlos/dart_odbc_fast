use crate::error::Result;
use odbc_api::Connection;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct DriverCapabilities {
    pub supports_prepared_statements: bool,
    pub supports_batch_operations: bool,
    pub supports_streaming: bool,
    pub max_row_array_size: u32,
    pub driver_name: String,
    pub driver_version: String,
}

impl DriverCapabilities {
    pub fn from_driver_name(driver_name: &str) -> Self {
        let normalized = driver_name.to_lowercase();
        match normalized.as_str() {
            "sqlserver" | "sql server" | "mssql" => Self {
                supports_prepared_statements: true,
                supports_batch_operations: true,
                supports_streaming: true,
                max_row_array_size: 2000,
                driver_name: "SQL Server".to_string(),
                driver_version: "Unknown".to_string(),
            },
            "postgres" | "postgresql" => Self {
                supports_prepared_statements: true,
                supports_batch_operations: true,
                supports_streaming: true,
                max_row_array_size: 2000,
                driver_name: "PostgreSQL".to_string(),
                driver_version: "Unknown".to_string(),
            },
            "mysql" => Self {
                supports_prepared_statements: true,
                supports_batch_operations: true,
                supports_streaming: true,
                max_row_array_size: 1500,
                driver_name: "MySQL".to_string(),
                driver_version: "Unknown".to_string(),
            },
            _ => Self::default(),
        }
    }

    pub fn detect_from_connection_string(connection_string: &str) -> Self {
        let lower = connection_string.to_lowercase();
        if lower.contains("sql server") || lower.contains("sqlserver") || lower.contains("mssql") {
            return Self::from_driver_name("sqlserver");
        }
        if lower.contains("postgres") || lower.contains("postgresql") {
            return Self::from_driver_name("postgres");
        }
        if lower.contains("mysql") {
            return Self::from_driver_name("mysql");
        }
        Self::default()
    }

    pub fn detect(_conn: &Connection<'static>) -> Result<Self> {
        Ok(Self::default())
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
    }

    #[test]
    fn test_driver_capabilities_to_json() {
        let caps = DriverCapabilities::from_driver_name("postgres");
        let payload = caps.to_json().expect("json payload");
        assert!(payload.contains("\"driver_name\":\"PostgreSQL\""));
        assert!(payload.contains("\"supports_prepared_statements\":true"));
    }
}

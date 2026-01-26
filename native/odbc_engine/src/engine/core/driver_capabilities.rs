use crate::error::Result;
use odbc_api::Connection;

#[derive(Debug, Clone)]
pub struct DriverCapabilities {
    pub supports_prepared_statements: bool,
    pub supports_batch_operations: bool,
    pub supports_streaming: bool,
    pub max_row_array_size: u32,
    pub driver_name: String,
    pub driver_version: String,
}

impl DriverCapabilities {
    pub fn detect(_conn: &Connection<'static>) -> Result<Self> {
        let supports_prepared_statements = true;
        let supports_batch_operations = true;
        let supports_streaming = true;
        let max_row_array_size = 1000;

        Ok(Self {
            supports_prepared_statements,
            supports_batch_operations,
            supports_streaming,
            max_row_array_size,
            driver_name: "Unknown".to_string(),
            driver_version: "Unknown".to_string(),
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
}

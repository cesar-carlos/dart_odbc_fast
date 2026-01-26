use log::Level;
use std::collections::HashMap;

pub struct StructuredLogger {
    enabled: bool,
}

impl StructuredLogger {
    pub fn new(enabled: bool) -> Self {
        Self { enabled }
    }

    pub fn log_query(&self, level: Level, query: &str, metadata: &HashMap<String, String>) {
        if !self.enabled {
            return;
        }

        let mut message = format!("Query: {}", query);
        for (key, value) in metadata {
            message.push_str(&format!(", {}={}", key, value));
        }

        log::log!(level, "{}", message);
    }

    pub fn log_connection(&self, level: Level, connection_string: &str, action: &str) {
        if !self.enabled {
            return;
        }

        log::log!(level, "Connection {}: {}", action, connection_string);
    }

    pub fn log_error(&self, error: &str, metadata: &HashMap<String, String>) {
        if !self.enabled {
            return;
        }

        let mut message = format!("Error: {}", error);
        for (key, value) in metadata {
            message.push_str(&format!(", {}={}", key, value));
        }

        log::error!("{}", message);
    }

    pub fn log_metric(&self, name: &str, value: f64, unit: &str) {
        if !self.enabled {
            return;
        }

        log::info!("Metric: {}={}{}", name, value, unit);
    }
}

impl Default for StructuredLogger {
    fn default() -> Self {
        Self::new(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_structured_logger_new() {
        let logger = StructuredLogger::new(true);
        assert!(logger.enabled);
    }

    #[test]
    fn test_structured_logger_default() {
        let logger = StructuredLogger::default();
        assert!(logger.enabled);
    }

    #[test]
    fn test_structured_logger_disabled() {
        let logger = StructuredLogger::new(false);
        assert!(!logger.enabled);
    }

    #[test]
    fn test_log_query_enabled() {
        let logger = StructuredLogger::new(true);
        let mut metadata = HashMap::new();
        metadata.insert("duration".to_string(), "100ms".to_string());
        metadata.insert("rows".to_string(), "42".to_string());

        logger.log_query(Level::Info, "SELECT * FROM users", &metadata);
    }

    #[test]
    fn test_log_query_disabled() {
        let logger = StructuredLogger::new(false);
        let metadata = HashMap::new();
        logger.log_query(Level::Info, "SELECT * FROM users", &metadata);
    }

    #[test]
    fn test_log_connection_enabled() {
        let logger = StructuredLogger::new(true);
        logger.log_connection(Level::Info, "DSN=test", "connect");
    }

    #[test]
    fn test_log_connection_disabled() {
        let logger = StructuredLogger::new(false);
        logger.log_connection(Level::Info, "DSN=test", "connect");
    }

    #[test]
    fn test_log_error_enabled() {
        let logger = StructuredLogger::new(true);
        let mut metadata = HashMap::new();
        metadata.insert("code".to_string(), "HY000".to_string());
        logger.log_error("Connection failed", &metadata);
    }

    #[test]
    fn test_log_error_disabled() {
        let logger = StructuredLogger::new(false);
        let metadata = HashMap::new();
        logger.log_error("Connection failed", &metadata);
    }

    #[test]
    fn test_log_metric_enabled() {
        let logger = StructuredLogger::new(true);
        logger.log_metric("query_latency", 123.45, "ms");
    }

    #[test]
    fn test_log_metric_disabled() {
        let logger = StructuredLogger::new(false);
        logger.log_metric("query_latency", 123.45, "ms");
    }

    #[test]
    fn test_log_query_different_levels() {
        let logger = StructuredLogger::new(true);
        let metadata = HashMap::new();
        logger.log_query(Level::Error, "SELECT * FROM users", &metadata);
        logger.log_query(Level::Warn, "SELECT * FROM users", &metadata);
        logger.log_query(Level::Info, "SELECT * FROM users", &metadata);
        logger.log_query(Level::Debug, "SELECT * FROM users", &metadata);
        logger.log_query(Level::Trace, "SELECT * FROM users", &metadata);
    }
}

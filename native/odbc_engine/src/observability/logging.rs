use log::Level;
use std::collections::HashMap;

/// Environment variable that opts-in to logging raw SQL (literals included).
/// When unset, [`sanitize_sql_for_log`] replaces literals with `?`.
pub const ENV_LOG_RAW_SQL: &str = "ODBC_FAST_LOG_RAW_SQL";

/// Replace string and numeric literals in `sql` with `?` so logs do not leak
/// PII or sensitive payload data (A8).
///
/// The implementation is intentionally simple: it scans the string, replacing
/// `'...'` (single-quoted strings, with `''` escape) and runs of digits/decimal
/// numbers with `?`. Identifiers in double quotes (`"name"`) are preserved.
///
/// Set `ODBC_FAST_LOG_RAW_SQL=1` to bypass sanitisation (useful in
/// dev/troubleshooting; never set in production).
pub fn sanitize_sql_for_log(sql: &str) -> String {
    if std::env::var(ENV_LOG_RAW_SQL)
        .map(|v| v == "1")
        .unwrap_or(false)
    {
        return sql.to_string();
    }
    let mut out = String::with_capacity(sql.len());
    let bytes = sql.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        match b {
            b'\'' => {
                out.push('?');
                i += 1;
                while i < bytes.len() {
                    if bytes[i] == b'\'' {
                        if i + 1 < bytes.len() && bytes[i + 1] == b'\'' {
                            i += 2;
                            continue;
                        }
                        i += 1;
                        break;
                    }
                    i += 1;
                }
            }
            b'0'..=b'9' => {
                out.push('?');
                while i < bytes.len() {
                    let c = bytes[i];
                    if c.is_ascii_digit()
                        || c == b'.'
                        || c == b'e'
                        || c == b'E'
                        || c == b'+'
                        || c == b'-'
                    {
                        i += 1;
                    } else {
                        break;
                    }
                }
            }
            _ => {
                // Push raw character (preserves UTF-8 because `b` matched ASCII fast path).
                // For multi-byte UTF-8, just copy the byte; we don't decode.
                out.push(b as char);
                i += 1;
            }
        }
    }
    out
}

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

        let sanitized = sanitize_sql_for_log(query);
        let mut message = format!("Query: {}", sanitized);
        for (key, value) in metadata {
            message.push_str(&format!(", {}={}", key, value));
        }

        log::log!(level, "{}", message);
    }

    pub fn log_connection(&self, level: Level, connection_string: &str, action: &str) {
        if !self.enabled {
            return;
        }

        let sanitized = crate::security::sanitize_connection_string(connection_string);
        log::log!(level, "Connection {}: {}", action, sanitized);
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

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

#[derive(Debug, Clone)]
pub struct AuditEvent {
    pub timestamp: SystemTime,
    pub event_type: String,
    pub user: Option<String>,
    pub connection_id: Option<u32>,
    pub query: Option<String>,
    pub metadata: HashMap<String, String>,
}

pub struct AuditLogger {
    events: Arc<Mutex<Vec<AuditEvent>>>,
    enabled: bool,
}

impl AuditLogger {
    pub fn new(enabled: bool) -> Self {
        Self {
            events: Arc::new(Mutex::new(Vec::new())),
            enabled,
        }
    }

    pub fn log_connection(&self, connection_id: u32, connection_string: &str) {
        if !self.enabled {
            return;
        }

        let mut metadata = HashMap::new();
        metadata.insert(
            "connection_string".to_string(),
            connection_string.to_string(),
        );

        let event = AuditEvent {
            timestamp: SystemTime::now(),
            event_type: "connection".to_string(),
            user: None,
            connection_id: Some(connection_id),
            query: None,
            metadata,
        };

        if let Ok(mut events) = self.events.lock() {
            events.push(event);
            if events.len() > 10000 {
                events.remove(0);
            }
        }
    }

    pub fn log_query(&self, connection_id: u32, query: &str) {
        if !self.enabled {
            return;
        }

        let event = AuditEvent {
            timestamp: SystemTime::now(),
            event_type: "query".to_string(),
            user: None,
            connection_id: Some(connection_id),
            query: Some(query.to_string()),
            metadata: HashMap::new(),
        };

        if let Ok(mut events) = self.events.lock() {
            events.push(event);
            if events.len() > 10000 {
                events.remove(0);
            }
        }
    }

    pub fn log_error(&self, connection_id: Option<u32>, error: &str) {
        if !self.enabled {
            return;
        }

        let mut metadata = HashMap::new();
        metadata.insert("error".to_string(), error.to_string());

        let event = AuditEvent {
            timestamp: SystemTime::now(),
            event_type: "error".to_string(),
            user: None,
            connection_id,
            query: None,
            metadata,
        };

        if let Ok(mut events) = self.events.lock() {
            events.push(event);
            if events.len() > 10000 {
                events.remove(0);
            }
        }
    }

    pub fn get_events(&self, limit: usize) -> Vec<AuditEvent> {
        if let Ok(events) = self.events.lock() {
            events.iter().rev().take(limit).cloned().collect()
        } else {
            Vec::new()
        }
    }
}

impl Default for AuditLogger {
    fn default() -> Self {
        Self::new(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_audit_logger_new_disabled() {
        let logger = AuditLogger::new(false);
        logger.log_connection(1, "DSN=test");
        assert!(logger.get_events(10).is_empty());
    }

    #[test]
    fn test_audit_logger_new_enabled_log_connection() {
        let logger = AuditLogger::new(true);
        logger.log_connection(42, "DSN=prod");
        let events = logger.get_events(10);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event_type, "connection");
        assert_eq!(events[0].connection_id, Some(42));
        assert_eq!(
            events[0].metadata.get("connection_string"),
            Some(&"DSN=prod".to_string())
        );
    }

    #[test]
    fn test_audit_logger_disabled_does_not_store_events() {
        let logger = AuditLogger::new(false);
        logger.log_connection(1, "conn");
        logger.log_query(1, "SELECT 1");
        logger.log_error(Some(1), "err");
        assert!(logger.get_events(10).is_empty());
    }

    #[test]
    fn test_audit_logger_enabled_log_query() {
        let logger = AuditLogger::new(true);
        logger.log_query(10, "SELECT * FROM t");
        let events = logger.get_events(10);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event_type, "query");
        assert_eq!(events[0].query.as_deref(), Some("SELECT * FROM t"));
    }

    #[test]
    fn test_audit_logger_enabled_log_error() {
        let logger = AuditLogger::new(true);
        logger.log_error(Some(5), "connection failed");
        let events = logger.get_events(10);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event_type, "error");
        assert_eq!(events[0].connection_id, Some(5));
        assert_eq!(
            events[0].metadata.get("error"),
            Some(&"connection failed".to_string())
        );
    }

    #[test]
    fn test_audit_logger_cap_10000_events() {
        let logger = AuditLogger::new(true);
        for i in 0..10001u32 {
            logger.log_connection(i, "dsn");
        }
        let events = logger.get_events(20_000);
        assert_eq!(events.len(), 10000);
        assert_eq!(events[0].connection_id, Some(10000));
        assert_eq!(events[9999].connection_id, Some(1));
    }

    #[test]
    fn test_audit_logger_get_events_limit() {
        let logger = AuditLogger::new(true);
        logger.log_connection(1, "a");
        logger.log_connection(2, "b");
        logger.log_connection(3, "c");
        let events = logger.get_events(2);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].connection_id, Some(3));
        assert_eq!(events[1].connection_id, Some(2));
    }

    #[test]
    fn test_audit_logger_default_enabled() {
        let logger = AuditLogger::default();
        logger.log_connection(1, "default");
        assert_eq!(logger.get_events(5).len(), 1);
    }
}

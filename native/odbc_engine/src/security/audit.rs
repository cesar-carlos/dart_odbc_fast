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

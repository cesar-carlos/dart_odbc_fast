#[cfg(test)]
mod tests {
    use odbc_engine::observability::*;
    use odbc_engine::security::*;
    use std::time::Duration;

    #[test]
    fn test_metrics() {
        let metrics = Metrics::new();

        metrics.record_query(Duration::from_millis(100));
        metrics.record_query(Duration::from_millis(200));
        metrics.record_query(Duration::from_millis(300));

        let query_metrics = metrics.get_query_metrics();
        assert_eq!(query_metrics.query_count, 3);
        assert!(query_metrics.average_latency() > Duration::ZERO);
        assert!(query_metrics.p95() > Duration::ZERO);
    }

    #[test]
    fn test_tracer() {
        let tracer = Tracer::new();

        let span_id = tracer.start_span("SELECT 1".to_string());
        assert!(span_id > 0);

        let span = tracer.finish_span(span_id);
        assert!(span.is_some());
        assert!(span.unwrap().duration().is_some());
    }

    #[test]
    fn test_secret_manager() {
        let manager = SecretManager::new();

        let secret = Secret::from_string("password123".to_string());
        manager.store("db_password".to_string(), secret).unwrap();

        let retrieved = manager.retrieve("db_password").unwrap();
        assert_eq!(retrieved.to_string_lossy(), "password123");
    }

    #[test]
    fn test_secure_buffer() {
        let buffer = SecuritySecureBuffer::from_string("sensitive_data".to_string());
        assert_eq!(buffer.to_string_lossy(), "sensitive_data");
    }

    #[test]
    fn test_audit_logger() {
        let logger = AuditLogger::new(true);

        logger.log_connection(1, "Driver={SQL Server};Server=localhost;");
        logger.log_query(1, "SELECT * FROM users");
        logger.log_error(Some(1), "Connection failed");

        let events = logger.get_events(10);
        assert_eq!(events.len(), 3);
        assert_eq!(events[0].event_type, "error");
        assert_eq!(events[1].event_type, "query");
        assert_eq!(events[2].event_type, "connection");
    }
}

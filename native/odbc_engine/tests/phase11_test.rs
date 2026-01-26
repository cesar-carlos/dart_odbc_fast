#[cfg(test)]
mod tests {
    use odbc_engine::engine::core::*;

    #[test]
    fn test_prepared_cache() {
        let cache = PreparedStatementCache::new(10);
        assert_eq!(cache.len(), 0);
        assert_eq!(cache.max_size(), 10);

        cache.get_or_insert("SELECT 1");
        assert_eq!(cache.len(), 1);

        cache.get_or_insert("SELECT 2");
        assert_eq!(cache.len(), 2);

        cache.clear();
        assert_eq!(cache.len(), 0);
    }

    #[test]
    fn test_protocol_version() {
        let v1 = ProtocolVersion::new(1, 0);
        let v2 = ProtocolVersion::new(1, 1);
        let v3 = ProtocolVersion::new(2, 0);

        assert!(v1.supports(&v1));
        assert!(v2.supports(&v1));
        assert!(!v1.supports(&v2));
        assert!(!v1.supports(&v3));
    }

    #[test]
    fn test_protocol_engine() {
        let engine = ProtocolEngine::current();
        let version = engine.version();
        assert_eq!(version.major, 1);
        assert_eq!(version.minor, 0);

        let client_v1 = ProtocolVersion::new(1, 0);
        let result = engine.negotiate(client_v1);
        assert!(result.is_ok());
    }

    #[test]
    fn test_memory_engine() {
        let engine = MemoryEngine::default();
        let buffer = engine.acquire_buffer();
        assert!(!buffer.is_empty());
        engine.release_buffer(buffer);
    }

    #[test]
    fn test_security_layer() {
        let layer = SecurityLayer::new();
        let data = vec![1, 2, 3, 4, 5];
        let secure = layer.secure_buffer(data);
        assert_eq!(secure.as_slice().len(), 5);
    }

    #[test]
    fn test_query_pipeline_parse() {
        let pipeline = QueryPipeline::new(100);

        let plan = pipeline.parse_sql("SELECT 1").unwrap();
        assert_eq!(plan.sql(), "SELECT 1");
        assert!(plan.use_cache());

        let result = pipeline.parse_sql("");
        assert!(result.is_err());
    }

    #[test]
    fn test_batch_executor() {
        let executor = BatchExecutor::new(100, 10);
        assert_eq!(executor.batch_size(), 10);
    }
}

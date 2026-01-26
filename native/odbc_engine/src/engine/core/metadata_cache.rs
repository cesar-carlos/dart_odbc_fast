use lru::LruCache;
use std::num::NonZeroUsize;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct ColumnMetadata {
    pub name: String,
    pub odbc_type: i16,
    pub nullable: bool,
}

#[derive(Debug, Clone)]
pub struct TableSchema {
    pub table_name: String,
    pub columns: Vec<ColumnMetadata>,
    pub cached_at: Instant,
}

pub struct MetadataCache {
    schemas: Arc<Mutex<LruCache<String, TableSchema>>>,
    ttl: Duration,
    max_size: usize,
}

impl MetadataCache {
    pub fn new(max_size: usize, ttl: Duration) -> Self {
        let capacity = NonZeroUsize::new(max_size.max(1)).unwrap_or_else(|| {
            NonZeroUsize::new(100).expect("NonZeroUsize::new(100) must succeed")
        });
        Self {
            schemas: Arc::new(Mutex::new(LruCache::new(capacity))),
            ttl,
            max_size: max_size.max(1),
        }
    }

    pub fn get_schema(&self, table: &str) -> Option<TableSchema> {
        let Ok(mut guard) = self.schemas.lock() else {
            return None;
        };
        let schema = guard.get(table)?.clone();
        if schema.cached_at.elapsed() > self.ttl {
            guard.pop(table);
            return None;
        }
        Some(schema)
    }

    pub fn cache_schema(&self, table: &str, schema: TableSchema) {
        if let Ok(mut guard) = self.schemas.lock() {
            guard.put(table.to_string(), schema);
        }
    }

    pub fn max_size(&self) -> usize {
        self.max_size
    }

    pub fn ttl(&self) -> Duration {
        self.ttl
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_metadata_cache_new() {
        let c = MetadataCache::new(50, Duration::from_secs(60));
        assert_eq!(c.max_size(), 50);
        assert_eq!(c.ttl(), Duration::from_secs(60));
    }

    #[test]
    fn test_metadata_cache_get_miss() {
        let c = MetadataCache::new(10, Duration::from_secs(60));
        assert!(c.get_schema("t1").is_none());
    }

    #[test]
    fn test_metadata_cache_cache_and_get() {
        let c = MetadataCache::new(10, Duration::from_secs(60));
        let s = TableSchema {
            table_name: "t1".to_string(),
            columns: vec![ColumnMetadata {
                name: "id".to_string(),
                odbc_type: 4,
                nullable: false,
            }],
            cached_at: Instant::now(),
        };
        c.cache_schema("t1", s);
        let got = c.get_schema("t1").expect("should be present");
        assert_eq!(got.table_name, "t1");
        assert_eq!(got.columns.len(), 1);
        assert_eq!(got.columns[0].name, "id");
        assert_eq!(got.columns[0].odbc_type, 4);
        assert!(!got.columns[0].nullable);
    }

    #[test]
    fn test_metadata_cache_ttl_expiry() {
        let c = MetadataCache::new(10, Duration::from_millis(1));
        let s = TableSchema {
            table_name: "t1".to_string(),
            columns: vec![],
            cached_at: Instant::now(),
        };
        c.cache_schema("t1", s);
        std::thread::sleep(Duration::from_millis(10));
        assert!(c.get_schema("t1").is_none());
    }
}

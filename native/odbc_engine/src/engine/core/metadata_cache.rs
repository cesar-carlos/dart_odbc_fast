use lru::LruCache;
use serde::Serialize;
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

/// Statistics for the metadata cache.
#[derive(Debug, Clone, Serialize)]
pub struct MetadataCacheStats {
    /// Maximum number of entries per cache.
    pub max_size: usize,
    /// Time-to-live in seconds.
    pub ttl_secs: u64,
    /// Current number of schema entries.
    pub schema_entries: usize,
    /// Current number of payload entries.
    pub payload_entries: usize,
}

pub struct MetadataCache {
    schemas: Arc<Mutex<LruCache<String, TableSchema>>>,
    payloads: Arc<Mutex<LruCache<String, CachedPayload>>>,
    ttl: Duration,
    max_size: usize,
}

#[derive(Debug, Clone)]
struct CachedPayload {
    data: Vec<u8>,
    cached_at: Instant,
}

impl MetadataCache {
    pub fn new(max_size: usize, ttl: Duration) -> Self {
        let capacity = NonZeroUsize::new(max_size.max(1)).unwrap_or_else(|| {
            NonZeroUsize::new(100).expect("NonZeroUsize::new(100) must succeed")
        });
        Self {
            schemas: Arc::new(Mutex::new(LruCache::new(capacity))),
            payloads: Arc::new(Mutex::new(LruCache::new(capacity))),
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

    pub fn get_payload(&self, key: &str) -> Option<Vec<u8>> {
        let Ok(mut guard) = self.payloads.lock() else {
            return None;
        };
        let payload = guard.get(key)?.clone();
        if payload.cached_at.elapsed() > self.ttl {
            guard.pop(key);
            return None;
        }
        Some(payload.data)
    }

    pub fn cache_payload(&self, key: &str, data: &[u8]) {
        if let Ok(mut guard) = self.payloads.lock() {
            guard.put(
                key.to_string(),
                CachedPayload {
                    data: data.to_vec(),
                    cached_at: Instant::now(),
                },
            );
        }
    }

    pub fn max_size(&self) -> usize {
        self.max_size
    }

    pub fn ttl(&self) -> Duration {
        self.ttl
    }

    /// Clears all cached schemas and payloads.
    pub fn clear(&self) {
        if let Ok(mut guard) = self.schemas.lock() {
            guard.clear();
        }
        if let Ok(mut guard) = self.payloads.lock() {
            guard.clear();
        }
    }

    /// Returns statistics about the cache.
    pub fn stats(&self) -> MetadataCacheStats {
        let schema_entries = self.schemas.lock().map(|guard| guard.len()).unwrap_or(0);
        let payload_entries = self.payloads.lock().map(|guard| guard.len()).unwrap_or(0);

        MetadataCacheStats {
            max_size: self.max_size,
            ttl_secs: self.ttl.as_secs(),
            schema_entries,
            payload_entries,
        }
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

    #[test]
    fn test_metadata_cache_payload_cache_and_get() {
        let c = MetadataCache::new(10, Duration::from_secs(60));
        c.cache_payload("1:users", &[1, 2, 3, 4]);
        let got = c.get_payload("1:users").expect("payload should be present");
        assert_eq!(got, vec![1, 2, 3, 4]);
    }

    #[test]
    fn test_metadata_cache_payload_ttl_expiry() {
        let c = MetadataCache::new(10, Duration::from_millis(1));
        c.cache_payload("1:users", &[9, 8, 7]);
        std::thread::sleep(Duration::from_millis(10));
        assert!(c.get_payload("1:users").is_none());
    }

    #[test]
    fn test_metadata_cache_clear() {
        let c = MetadataCache::new(10, Duration::from_secs(60));
        c.cache_payload("key1", &[1, 2, 3]);
        c.cache_payload("key2", &[4, 5, 6]);

        let s = TableSchema {
            table_name: "t1".to_string(),
            columns: vec![],
            cached_at: Instant::now(),
        };
        c.cache_schema("t1", s);

        let stats = c.stats();
        assert_eq!(stats.schema_entries, 1);
        assert_eq!(stats.payload_entries, 2);

        c.clear();

        let stats = c.stats();
        assert_eq!(stats.schema_entries, 0);
        assert_eq!(stats.payload_entries, 0);
    }

    #[test]
    fn test_metadata_cache_stats() {
        let c = MetadataCache::new(100, Duration::from_secs(300));

        let stats = c.stats();
        assert_eq!(stats.max_size, 100);
        assert_eq!(stats.ttl_secs, 300);
        assert_eq!(stats.schema_entries, 0);
        assert_eq!(stats.payload_entries, 0);

        c.cache_payload("key1", &[1, 2, 3]);
        let stats = c.stats();
        assert_eq!(stats.payload_entries, 1);
    }

    #[test]
    fn test_metadata_cache_stats_serialization() {
        let c = MetadataCache::new(50, Duration::from_secs(120));
        c.cache_payload("k1", &[1]);

        let stats = c.stats();
        let json = serde_json::to_string(&stats).expect("should serialize");
        assert!(json.contains("\"max_size\":50"));
        assert!(json.contains("\"ttl_secs\":120"));
        assert!(json.contains("\"payload_entries\":1"));
    }

    #[test]
    fn test_metadata_cache_lru_eviction_payload() {
        // Create a cache with max_size = 3
        let c = MetadataCache::new(3, Duration::from_secs(60));

        // Add 3 entries (fills the cache)
        c.cache_payload("key1", &[1]);
        c.cache_payload("key2", &[2]);
        c.cache_payload("key3", &[3]);

        let stats = c.stats();
        assert_eq!(stats.payload_entries, 3);

        // All entries should be present
        assert!(c.get_payload("key1").is_some());
        assert!(c.get_payload("key2").is_some());
        assert!(c.get_payload("key3").is_some());

        // Add a 4th entry - should evict the least recently used (key1)
        c.cache_payload("key4", &[4]);

        let stats = c.stats();
        assert_eq!(stats.payload_entries, 3);

        // key1 should be evicted
        assert!(
            c.get_payload("key1").is_none(),
            "key1 should have been evicted"
        );

        // key2, key3, key4 should still be present
        assert!(c.get_payload("key2").is_some());
        assert!(c.get_payload("key3").is_some());
        assert!(c.get_payload("key4").is_some());
    }

    #[test]
    fn test_metadata_cache_lru_eviction_with_access() {
        // Create a cache with max_size = 3
        let c = MetadataCache::new(3, Duration::from_secs(60));

        // Add 3 entries
        c.cache_payload("key1", &[1]);
        c.cache_payload("key2", &[2]);
        c.cache_payload("key3", &[3]);

        // Access key1 to make it recently used
        let _ = c.get_payload("key1");

        // Add a 4th entry - should evict key2 (LRU), not key1
        c.cache_payload("key4", &[4]);

        // key1 should still be present (was accessed recently)
        assert!(
            c.get_payload("key1").is_some(),
            "key1 should still be present after access"
        );

        // key2 should be evicted (was the LRU)
        assert!(
            c.get_payload("key2").is_none(),
            "key2 should have been evicted"
        );

        // key3 and key4 should be present
        assert!(c.get_payload("key3").is_some());
        assert!(c.get_payload("key4").is_some());
    }

    #[test]
    fn test_metadata_cache_lru_eviction_schema() {
        // Create a cache with max_size = 2
        let c = MetadataCache::new(2, Duration::from_secs(60));

        let make_schema = |name: &str| TableSchema {
            table_name: name.to_string(),
            columns: vec![],
            cached_at: Instant::now(),
        };

        // Add 2 entries (fills the cache)
        c.cache_schema("table1", make_schema("table1"));
        c.cache_schema("table2", make_schema("table2"));

        let stats = c.stats();
        assert_eq!(stats.schema_entries, 2);

        // Add a 3rd entry - should evict table1 (LRU)
        c.cache_schema("table3", make_schema("table3"));

        let stats = c.stats();
        assert_eq!(stats.schema_entries, 2);

        // table1 should be evicted
        assert!(
            c.get_schema("table1").is_none(),
            "table1 should have been evicted"
        );

        // table2 and table3 should be present
        assert!(c.get_schema("table2").is_some());
        assert!(c.get_schema("table3").is_some());
    }
}

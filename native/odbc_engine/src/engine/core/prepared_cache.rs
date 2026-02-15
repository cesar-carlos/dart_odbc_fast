use lru::LruCache;
use std::num::NonZeroUsize;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// Metrics for prepared statement cache.
#[derive(Debug, Clone, Copy)]
pub struct PreparedStatementMetrics {
    pub cache_size: usize,
    pub cache_max_size: usize,
    pub cache_hits: u64,
    pub cache_misses: u64,
    pub total_prepares: u64,
    pub total_executions: u64,
    pub avg_executions_per_stmt: f64,
    pub memory_usage_bytes: usize,
}

pub struct PreparedStatementCache {
    cache: Arc<Mutex<LruCache<String, ()>>>,
    max_size: usize,
    cache_hits: Arc<AtomicU64>,
    cache_misses: Arc<AtomicU64>,
    total_prepares: Arc<AtomicU64>,
    total_executions: Arc<AtomicU64>,
}

impl PreparedStatementCache {
    pub fn new(max_size: usize) -> Self {
        let capacity = NonZeroUsize::new(max_size).unwrap_or_else(|| {
            NonZeroUsize::new(100).expect("NonZeroUsize::new(100) must succeed")
        });

        Self {
            cache: Arc::new(Mutex::new(LruCache::new(capacity))),
            max_size,
            cache_hits: Arc::new(AtomicU64::new(0)),
            cache_misses: Arc::new(AtomicU64::new(0)),
            total_prepares: Arc::new(AtomicU64::new(0)),
            total_executions: Arc::new(AtomicU64::new(0)),
        }
    }

    pub fn get_or_insert(&self, sql: &str) -> bool {
        let Ok(mut cache) = self.cache.lock() else {
            log::error!("PreparedStatementCache mutex poisoned");
            return false;
        };
        if cache.contains(sql) {
            self.cache_hits.fetch_add(1, Ordering::Relaxed);
            true
        } else {
            self.cache_misses.fetch_add(1, Ordering::Relaxed);
            self.total_prepares.fetch_add(1, Ordering::Relaxed);
            cache.put(sql.to_string(), ());
            false
        }
    }

    pub fn record_execution(&self) {
        self.total_executions.fetch_add(1, Ordering::Relaxed);
    }

    pub fn cache_hits(&self) -> u64 {
        self.cache_hits.load(Ordering::Relaxed)
    }

    pub fn cache_misses(&self) -> u64 {
        self.cache_misses.load(Ordering::Relaxed)
    }

    pub fn total_prepares(&self) -> u64 {
        self.total_prepares.load(Ordering::Relaxed)
    }

    pub fn total_executions(&self) -> u64 {
        self.total_executions.load(Ordering::Relaxed)
    }

    pub fn avg_executions_per_stmt(&self) -> f64 {
        let prepares = self.total_prepares();
        if prepares == 0 {
            0.0
        } else {
            self.total_executions() as f64 / prepares as f64
        }
    }

    pub fn get_metrics(&self) -> PreparedStatementMetrics {
        PreparedStatementMetrics {
            cache_size: self.len(),
            cache_max_size: self.max_size,
            cache_hits: self.cache_hits(),
            cache_misses: self.cache_misses(),
            total_prepares: self.total_prepares(),
            total_executions: self.total_executions(),
            avg_executions_per_stmt: self.avg_executions_per_stmt(),
            memory_usage_bytes: self.len() * 64, // Approximation
        }
    }

    pub fn clear(&self) {
        if let Ok(mut cache) = self.cache.lock() {
            cache.clear();
        } else {
            log::error!("PreparedStatementCache mutex poisoned on clear");
        }
    }

    pub fn len(&self) -> usize {
        self.cache.lock().map(|c| c.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn max_size(&self) -> usize {
        self.max_size
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_prepared_cache_new() {
        let cache = PreparedStatementCache::new(100);
        assert_eq!(cache.max_size(), 100);
        assert!(cache.is_empty());
        assert_eq!(cache.len(), 0);
    }

    #[test]
    fn test_prepared_cache_new_with_zero() {
        let cache = PreparedStatementCache::new(0);
        assert_eq!(cache.max_size(), 0);
    }

    #[test]
    fn test_get_or_insert() {
        let cache = PreparedStatementCache::new(10);

        let result1 = cache.get_or_insert("SELECT 1");
        assert!(!result1);
        assert_eq!(cache.len(), 1);

        let result2 = cache.get_or_insert("SELECT 1");
        assert!(result2);
        assert_eq!(cache.len(), 1);

        let result3 = cache.get_or_insert("SELECT 2");
        assert!(!result3);
        assert_eq!(cache.len(), 2);
    }

    #[test]
    fn test_clear() {
        let cache = PreparedStatementCache::new(10);

        cache.get_or_insert("SELECT 1");
        cache.get_or_insert("SELECT 2");
        assert_eq!(cache.len(), 2);

        cache.clear();
        assert!(cache.is_empty());
        assert_eq!(cache.len(), 0);
    }

    #[test]
    fn test_len() {
        let cache = PreparedStatementCache::new(10);
        assert_eq!(cache.len(), 0);

        cache.get_or_insert("SELECT 1");
        assert_eq!(cache.len(), 1);

        cache.get_or_insert("SELECT 2");
        assert_eq!(cache.len(), 2);

        cache.get_or_insert("SELECT 1");
        assert_eq!(cache.len(), 2);
    }

    #[test]
    fn test_is_empty() {
        let cache = PreparedStatementCache::new(10);
        assert!(cache.is_empty());

        cache.get_or_insert("SELECT 1");
        assert!(!cache.is_empty());

        cache.clear();
        assert!(cache.is_empty());
    }

    #[test]
    fn test_max_size() {
        let cache1 = PreparedStatementCache::new(50);
        assert_eq!(cache1.max_size(), 50);

        let cache2 = PreparedStatementCache::new(200);
        assert_eq!(cache2.max_size(), 200);
    }

    #[test]
    fn test_lru_eviction() {
        let cache = PreparedStatementCache::new(3);

        cache.get_or_insert("SELECT 1");
        cache.get_or_insert("SELECT 2");
        cache.get_or_insert("SELECT 3");
        assert_eq!(cache.len(), 3);

        cache.get_or_insert("SELECT 4");
        assert_eq!(cache.len(), 3);

        let exists_1 = cache.get_or_insert("SELECT 1");
        assert!(!exists_1);
    }
}

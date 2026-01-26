use lru::LruCache;
use std::num::NonZeroUsize;
use std::sync::{Arc, Mutex};

pub struct PreparedStatementCache {
    cache: Arc<Mutex<LruCache<String, ()>>>,
    max_size: usize,
}

impl PreparedStatementCache {
    pub fn new(max_size: usize) -> Self {
        let capacity = NonZeroUsize::new(max_size).unwrap_or_else(|| {
            NonZeroUsize::new(100).expect("NonZeroUsize::new(100) must succeed")
        });

        Self {
            cache: Arc::new(Mutex::new(LruCache::new(capacity))),
            max_size,
        }
    }

    pub fn get_or_insert(&self, sql: &str) -> bool {
        let Ok(mut cache) = self.cache.lock() else {
            log::error!("PreparedStatementCache mutex poisoned");
            return false;
        };
        if cache.contains(sql) {
            true
        } else {
            cache.put(sql.to_string(), ());
            false
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

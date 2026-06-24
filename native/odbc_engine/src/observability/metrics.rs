//! Standard metrics for critical operations.
//!
//! ## Minimal metrics per operation
//!
//! - **Query execution**: `record_query(latency)` → query_count, total_latency, min/max, p50/p95/p99
//! - **Errors**: `record_error()` → error_count
//! - **Pool**: `update_pool_metrics()` → pool_id, total/active/idle connections, requests, errors
//! - **Uptime**: `start_time.elapsed()` from Metrics creation
//!
//! Exposed via `odbc_get_metrics` (40 bytes) and `odbc_get_cache_metrics` (64 bytes).

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::engine::PreparedStatementCache;

const MAX_LATENCY_SAMPLES: usize = 1000;
const HISTOGRAM_BUCKET_COUNT: usize = 16;

/// Fixed-bucket latency histogram (microsecond lower bounds per bucket).
const HISTOGRAM_UPPER_MICROS: [u64; HISTOGRAM_BUCKET_COUNT] = [
    1,
    2,
    5,
    10,
    25,
    50,
    100,
    250,
    500,
    1_000,
    2_500,
    5_000,
    10_000,
    25_000,
    100_000,
    u64::MAX,
];

#[derive(Debug, Clone)]
struct LatencyHistogram {
    buckets: [u64; HISTOGRAM_BUCKET_COUNT],
}

impl Default for LatencyHistogram {
    fn default() -> Self {
        Self::new()
    }
}

impl LatencyHistogram {
    fn new() -> Self {
        Self {
            buckets: [0; HISTOGRAM_BUCKET_COUNT],
        }
    }

    fn record(&mut self, latency: Duration) {
        self.buckets[Self::bucket_index(latency)] += 1;
    }

    fn bucket_index(latency: Duration) -> usize {
        let micros = latency.as_micros().min(u64::MAX as u128) as u64;
        HISTOGRAM_UPPER_MICROS
            .iter()
            .position(|&upper| micros <= upper)
            .unwrap_or(HISTOGRAM_BUCKET_COUNT - 1)
    }

    fn percentile(&self, p: f64) -> Duration {
        let total: u64 = self.buckets.iter().sum();
        if total == 0 {
            return Duration::ZERO;
        }
        let target = ((total as f64) * p / 100.0).ceil() as u64;
        let mut seen = 0u64;
        for (idx, &count) in self.buckets.iter().enumerate() {
            seen += count;
            if seen >= target {
                return Duration::from_micros(HISTOGRAM_UPPER_MICROS[idx]);
            }
        }
        Duration::from_micros(HISTOGRAM_UPPER_MICROS[HISTOGRAM_BUCKET_COUNT - 1])
    }
}

#[derive(Debug, Clone)]
pub struct QueryMetrics {
    pub query_count: u64,
    pub total_latency: Duration,
    pub min_latency: Duration,
    pub max_latency: Duration,
    pub latency_samples: VecDeque<Duration>,
    latency_histogram: LatencyHistogram,
}

impl Default for QueryMetrics {
    fn default() -> Self {
        Self::new()
    }
}

impl QueryMetrics {
    pub fn new() -> Self {
        Self {
            query_count: 0,
            total_latency: Duration::ZERO,
            min_latency: Duration::MAX,
            max_latency: Duration::ZERO,
            latency_samples: VecDeque::with_capacity(MAX_LATENCY_SAMPLES),
            latency_histogram: LatencyHistogram::new(),
        }
    }

    pub fn record_query(&mut self, latency: Duration) {
        self.query_count += 1;
        self.total_latency += latency;

        if latency < self.min_latency {
            self.min_latency = latency;
        }
        if latency > self.max_latency {
            self.max_latency = latency;
        }

        self.latency_histogram.record(latency);
        self.latency_samples.push_back(latency);
        if self.latency_samples.len() > MAX_LATENCY_SAMPLES {
            self.latency_samples.pop_front();
        }
    }

    fn percentile_from_samples(&self, p: f64) -> Duration {
        if self.latency_samples.is_empty() {
            return Duration::ZERO;
        }
        let mut sorted: Vec<Duration> = self.latency_samples.iter().copied().collect();
        sorted.sort_unstable();
        let index = ((sorted.len() - 1) as f64 * p / 100.0) as usize;
        sorted[index]
    }

    pub fn average_latency(&self) -> Duration {
        if self.query_count == 0 {
            return Duration::ZERO;
        }
        self.total_latency / self.query_count as u32
    }

    pub fn percentile(&self, p: f64) -> Duration {
        if self.latency_samples.is_empty() {
            return Duration::ZERO;
        }
        if self.latency_samples.len() >= MAX_LATENCY_SAMPLES {
            return self.latency_histogram.percentile(p);
        }
        self.percentile_from_samples(p)
    }

    pub fn p50(&self) -> Duration {
        self.percentile(50.0)
    }

    pub fn p95(&self) -> Duration {
        self.percentile(95.0)
    }

    pub fn p99(&self) -> Duration {
        self.percentile(99.0)
    }

    pub fn throughput(&self, window: Duration) -> f64 {
        if window.as_secs() == 0 {
            return 0.0;
        }
        self.query_count as f64 / window.as_secs() as f64
    }
}

#[derive(Debug, Clone)]
pub struct PoolMetrics {
    pub pool_id: u32,
    pub total_connections: u32,
    pub active_connections: u32,
    pub idle_connections: u32,
    pub connection_requests: u64,
    pub connection_errors: u64,
}

impl PoolMetrics {
    pub fn new(pool_id: u32) -> Self {
        Self {
            pool_id,
            total_connections: 0,
            active_connections: 0,
            idle_connections: 0,
            connection_requests: 0,
            connection_errors: 0,
        }
    }
}

pub struct Metrics {
    query_metrics: Arc<Mutex<QueryMetrics>>,
    pool_metrics: Arc<Mutex<std::collections::HashMap<u32, PoolMetrics>>>,
    error_count: AtomicU64,
    start_time: Instant,
    prepared_cache: Arc<Mutex<Option<Arc<PreparedStatementCache>>>>,
}

impl Metrics {
    pub fn new() -> Self {
        Self {
            query_metrics: Arc::new(Mutex::new(QueryMetrics::new())),
            pool_metrics: Arc::new(Mutex::new(std::collections::HashMap::new())),
            error_count: AtomicU64::new(0),
            start_time: Instant::now(),
            prepared_cache: Arc::new(Mutex::new(None)),
        }
    }

    pub fn set_prepared_cache(&self, cache: Arc<PreparedStatementCache>) {
        if let Ok(mut pc) = self.prepared_cache.lock() {
            *pc = Some(cache);
        }
    }

    pub fn record_query(&self, latency: Duration) {
        if let Ok(mut metrics) = self.query_metrics.lock() {
            metrics.record_query(latency);
        }
    }

    pub fn record_error(&self) {
        self.error_count.fetch_add(1, Ordering::Relaxed);
    }

    pub fn update_pool_metrics(&self, pool_id: u32, metrics: PoolMetrics) {
        if let Ok(mut pools) = self.pool_metrics.lock() {
            pools.insert(pool_id, metrics);
        }
    }

    pub fn get_query_metrics(&self) -> QueryMetrics {
        self.query_metrics
            .lock()
            .map(|m| m.clone())
            .unwrap_or_else(|_| QueryMetrics::new())
    }

    pub fn get_pool_metrics(&self, pool_id: u32) -> Option<PoolMetrics> {
        self.pool_metrics
            .lock()
            .ok()
            .and_then(|pools| pools.get(&pool_id).cloned())
    }

    pub fn get_error_count(&self) -> u64 {
        self.error_count.load(Ordering::Relaxed)
    }

    pub fn uptime(&self) -> Duration {
        self.start_time.elapsed()
    }

    pub fn get_prepared_cache_metrics(&self) -> Option<crate::engine::PreparedStatementMetrics> {
        self.prepared_cache
            .lock()
            .ok()
            .and_then(|cache| cache.as_ref().map(|c| c.get_metrics()))
    }

    pub fn clear_prepared_cache(&self) {
        if let Ok(cache) = self.prepared_cache.lock() {
            if let Some(c) = cache.as_ref() {
                c.clear();
            }
        }
    }
}

impl Default for Metrics {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_query_metrics_new() {
        let metrics = QueryMetrics::new();
        assert_eq!(metrics.query_count, 0);
        assert_eq!(metrics.total_latency, Duration::ZERO);
        assert_eq!(metrics.min_latency, Duration::MAX);
        assert_eq!(metrics.max_latency, Duration::ZERO);
        assert!(metrics.latency_samples.is_empty());
    }

    #[test]
    fn test_query_metrics_default() {
        let metrics = QueryMetrics::default();
        assert_eq!(metrics.query_count, 0);
    }

    #[test]
    fn test_query_metrics_record_query() {
        let mut metrics = QueryMetrics::new();
        let latency = Duration::from_millis(100);
        metrics.record_query(latency);

        assert_eq!(metrics.query_count, 1);
        assert_eq!(metrics.total_latency, latency);
        assert_eq!(metrics.min_latency, latency);
        assert_eq!(metrics.max_latency, latency);
        assert_eq!(metrics.latency_samples.len(), 1);
    }

    #[test]
    fn test_query_metrics_record_multiple_queries() {
        let mut metrics = QueryMetrics::new();
        metrics.record_query(Duration::from_millis(50));
        metrics.record_query(Duration::from_millis(100));
        metrics.record_query(Duration::from_millis(75));

        assert_eq!(metrics.query_count, 3);
        assert_eq!(metrics.min_latency, Duration::from_millis(50));
        assert_eq!(metrics.max_latency, Duration::from_millis(100));
        assert_eq!(metrics.latency_samples.len(), 3);
    }

    #[test]
    fn test_query_metrics_average_latency() {
        let mut metrics = QueryMetrics::new();
        assert_eq!(metrics.average_latency(), Duration::ZERO);

        metrics.record_query(Duration::from_millis(100));
        metrics.record_query(Duration::from_millis(200));
        assert_eq!(metrics.average_latency(), Duration::from_millis(150));
    }

    #[test]
    fn test_query_metrics_percentile() {
        let mut metrics = QueryMetrics::new();
        assert_eq!(metrics.percentile(50.0), Duration::ZERO);

        for i in 1..=10 {
            metrics.record_query(Duration::from_millis(i * 10));
        }

        let p50 = metrics.percentile(50.0);
        assert!(p50 >= Duration::from_millis(50));
        assert!(p50 <= Duration::from_millis(60));
    }

    #[test]
    fn test_query_metrics_p50_p95_p99() {
        let mut metrics = QueryMetrics::new();
        for i in 1..=100 {
            metrics.record_query(Duration::from_millis(i));
        }

        let p50 = metrics.p50();
        let p95 = metrics.p95();
        let p99 = metrics.p99();

        assert!(p50 > Duration::ZERO);
        assert!(p95 > p50);
        assert!(p99 >= p95);
    }

    #[test]
    fn test_query_metrics_throughput() {
        let mut metrics = QueryMetrics::new();
        metrics.record_query(Duration::from_millis(100));
        metrics.record_query(Duration::from_millis(100));

        let throughput = metrics.throughput(Duration::from_secs(1));
        assert!(throughput > 0.0);
    }

    #[test]
    fn test_query_metrics_throughput_zero_window() {
        let mut metrics = QueryMetrics::new();
        metrics.record_query(Duration::from_millis(100));
        assert_eq!(metrics.throughput(Duration::ZERO), 0.0);
    }

    #[test]
    fn test_query_metrics_sample_limit() {
        let mut metrics = QueryMetrics::new();
        for i in 0..1500 {
            metrics.record_query(Duration::from_millis(i));
        }
        assert_eq!(metrics.latency_samples.len(), 1000);
        assert_eq!(metrics.query_count, 1500);
    }

    #[test]
    fn test_query_metrics_sample_window_evicts_oldest() {
        let mut metrics = QueryMetrics::new();
        for i in 0..=MAX_LATENCY_SAMPLES {
            metrics.record_query(Duration::from_millis(i as u64));
        }

        assert_eq!(metrics.latency_samples.len(), MAX_LATENCY_SAMPLES);
        assert_eq!(
            metrics.latency_samples.front(),
            Some(&Duration::from_millis(1))
        );
        assert_eq!(
            metrics.latency_samples.back(),
            Some(&Duration::from_millis(MAX_LATENCY_SAMPLES as u64))
        );
    }

    #[test]
    fn test_query_metrics_percentile_uses_histogram_when_window_full() {
        let mut metrics = QueryMetrics::new();
        for i in 0..1500 {
            metrics.record_query(Duration::from_millis(i));
        }

        let p0 = metrics.percentile(0.0);
        let p100 = metrics.percentile(100.0);
        assert!(p0 <= Duration::from_millis(10));
        assert!(p100 >= Duration::from_millis(1000));
    }

    #[test]
    fn test_pool_metrics_new() {
        let metrics = PoolMetrics::new(42);
        assert_eq!(metrics.pool_id, 42);
        assert_eq!(metrics.total_connections, 0);
        assert_eq!(metrics.active_connections, 0);
        assert_eq!(metrics.idle_connections, 0);
        assert_eq!(metrics.connection_requests, 0);
        assert_eq!(metrics.connection_errors, 0);
    }

    #[test]
    fn test_metrics_new() {
        let metrics = Metrics::new();
        let query_metrics = metrics.get_query_metrics();
        assert_eq!(query_metrics.query_count, 0);
        assert_eq!(metrics.get_error_count(), 0);
    }

    #[test]
    fn test_metrics_default() {
        let metrics = Metrics::default();
        assert_eq!(metrics.get_query_metrics().query_count, 0);
    }

    #[test]
    fn test_metrics_record_query() {
        let metrics = Metrics::new();
        metrics.record_query(Duration::from_millis(100));
        let query_metrics = metrics.get_query_metrics();
        assert_eq!(query_metrics.query_count, 1);
    }

    #[test]
    fn test_metrics_record_error() {
        let metrics = Metrics::new();
        assert_eq!(metrics.get_error_count(), 0);
        metrics.record_error();
        assert_eq!(metrics.get_error_count(), 1);
        metrics.record_error();
        assert_eq!(metrics.get_error_count(), 2);
    }

    #[test]
    fn test_metrics_update_pool_metrics() {
        let metrics = Metrics::new();
        let pool_metrics = PoolMetrics::new(1);
        metrics.update_pool_metrics(1, pool_metrics);

        let retrieved = metrics.get_pool_metrics(1);
        assert!(retrieved.is_some());
        assert_eq!(retrieved.unwrap().pool_id, 1);
    }

    #[test]
    fn test_metrics_get_pool_metrics_not_found() {
        let metrics = Metrics::new();
        let retrieved = metrics.get_pool_metrics(999);
        assert!(retrieved.is_none());
    }

    #[test]
    fn test_metrics_uptime() {
        let metrics = Metrics::new();
        std::thread::sleep(Duration::from_millis(10));
        let uptime = metrics.uptime();
        assert!(uptime >= Duration::from_millis(10));
    }
}

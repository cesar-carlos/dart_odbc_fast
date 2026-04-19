use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub struct QuerySpan {
    pub span_id: u64,
    pub query: String,
    pub start_time: Instant,
    pub end_time: Option<Instant>,
    pub metadata: HashMap<String, String>,
}

impl QuerySpan {
    pub fn new(span_id: u64, query: String) -> Self {
        Self {
            span_id,
            query,
            start_time: Instant::now(),
            end_time: None,
            metadata: HashMap::new(),
        }
    }

    pub fn finish(&mut self) {
        self.end_time = Some(Instant::now());
    }

    pub fn duration(&self) -> Option<Duration> {
        self.end_time.map(|end| end.duration_since(self.start_time))
    }

    pub fn add_metadata(&mut self, key: String, value: String) {
        self.metadata.insert(key, value);
    }
}

pub struct Tracer {
    spans: Arc<Mutex<HashMap<u64, QuerySpan>>>,
    next_span_id: Arc<Mutex<u64>>,
}

impl Tracer {
    pub fn new() -> Self {
        Self {
            spans: Arc::new(Mutex::new(HashMap::new())),
            next_span_id: Arc::new(Mutex::new(1)),
        }
    }

    pub fn start_span(&self, query: String) -> u64 {
        let mut next_id = self.next_span_id.lock().unwrap_or_else(|e| e.into_inner());
        let span_id = *next_id;
        *next_id += 1;

        let span = QuerySpan::new(span_id, query);
        if let Ok(mut spans) = self.spans.lock() {
            spans.insert(span_id, span);
        } else {
            log::warn!("Tracer spans lock poisoned; span {} not recorded", span_id);
        }

        span_id
    }

    pub fn finish_span(&self, span_id: u64) -> Option<QuerySpan> {
        let mut spans = self.spans.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut span) = spans.remove(&span_id) {
            span.finish();
            Some(span)
        } else {
            None
        }
    }

    pub fn add_metadata(&self, span_id: u64, key: String, value: String) {
        if let Ok(mut spans) = self.spans.lock() {
            if let Some(span) = spans.get_mut(&span_id) {
                span.add_metadata(key, value);
            }
        }
    }

    /// Number of in-flight spans (started but not yet finished).
    /// Useful for leak detection in tests.
    pub fn active_span_count(&self) -> usize {
        self.spans
            .lock()
            .map(|s| s.len())
            .unwrap_or_else(|e| e.into_inner().len())
    }
}

impl Default for Tracer {
    fn default() -> Self {
        Self::new()
    }
}

/// RAII guard that ensures a span is finished even if the surrounding code
/// returns early via `?` or panics.
///
/// Replaces the manual `start_span`/`finish_span` pattern that previously
/// leaked spans on error paths.
///
/// # Example
///
/// ```
/// use std::sync::Arc;
/// use odbc_engine::observability::{SpanGuard, Tracer};
/// fn run(tracer: Arc<Tracer>) -> Result<(), &'static str> {
///     let _guard = SpanGuard::new(Arc::clone(&tracer), "select 1".to_string());
///     // any early return finishes the span automatically
///     Err("boom")
/// }
/// ```
pub struct SpanGuard {
    tracer: Arc<Tracer>,
    span_id: u64,
    finished: bool,
}

impl SpanGuard {
    /// Start a new span and return a guard that finishes it on drop.
    pub fn new(tracer: Arc<Tracer>, query: String) -> Self {
        let span_id = tracer.start_span(query);
        Self {
            tracer,
            span_id,
            finished: false,
        }
    }

    /// Span id, useful when the caller needs to attach metadata.
    pub fn span_id(&self) -> u64 {
        self.span_id
    }

    /// Attach metadata to the underlying span.
    pub fn add_metadata(&self, key: impl Into<String>, value: impl Into<String>) {
        self.tracer
            .add_metadata(self.span_id, key.into(), value.into());
    }

    /// Explicitly finish the span and return it. Subsequent `Drop` is a no-op.
    pub fn finish(mut self) -> Option<QuerySpan> {
        self.finished = true;
        self.tracer.finish_span(self.span_id)
    }
}

impl Drop for SpanGuard {
    fn drop(&mut self) {
        if !self.finished {
            // Discard the returned span; this is the implicit cleanup path.
            let _ = self.tracer.finish_span(self.span_id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_query_span_new() {
        let span = QuerySpan::new(1, "SELECT * FROM users".to_string());
        assert_eq!(span.span_id, 1);
        assert_eq!(span.query, "SELECT * FROM users");
        assert!(span.end_time.is_none());
        assert!(span.metadata.is_empty());
    }

    #[test]
    fn test_query_span_finish() {
        let mut span = QuerySpan::new(1, "SELECT * FROM users".to_string());
        std::thread::sleep(Duration::from_millis(10));
        span.finish();
        assert!(span.end_time.is_some());
        assert!(span.duration().is_some());
        assert!(span.duration().unwrap() >= Duration::from_millis(10));
    }

    #[test]
    fn test_query_span_duration_not_finished() {
        let span = QuerySpan::new(1, "SELECT * FROM users".to_string());
        assert!(span.duration().is_none());
    }

    #[test]
    fn test_query_span_add_metadata() {
        let mut span = QuerySpan::new(1, "SELECT * FROM users".to_string());
        span.add_metadata("table".to_string(), "users".to_string());
        span.add_metadata("rows".to_string(), "42".to_string());

        assert_eq!(span.metadata.len(), 2);
        assert_eq!(span.metadata.get("table"), Some(&"users".to_string()));
        assert_eq!(span.metadata.get("rows"), Some(&"42".to_string()));
    }

    #[test]
    fn test_tracer_new() {
        let tracer = Tracer::new();
        let span_id = tracer.start_span("SELECT * FROM users".to_string());
        assert_eq!(span_id, 1);
    }

    #[test]
    fn test_tracer_default() {
        let tracer = Tracer::default();
        let span_id = tracer.start_span("SELECT * FROM users".to_string());
        assert_eq!(span_id, 1);
    }

    #[test]
    fn test_tracer_start_span() {
        let tracer = Tracer::new();
        let span_id1 = tracer.start_span("SELECT * FROM users".to_string());
        let span_id2 = tracer.start_span("SELECT * FROM orders".to_string());

        assert_eq!(span_id1, 1);
        assert_eq!(span_id2, 2);
    }

    #[test]
    fn test_tracer_finish_span() {
        let tracer = Tracer::new();
        let span_id = tracer.start_span("SELECT * FROM users".to_string());
        std::thread::sleep(Duration::from_millis(10));
        let span = tracer.finish_span(span_id);

        assert!(span.is_some());
        let finished_span = span.unwrap();
        assert_eq!(finished_span.span_id, span_id);
        assert_eq!(finished_span.query, "SELECT * FROM users");
        assert!(finished_span.end_time.is_some());
        assert!(finished_span.duration().is_some());
    }

    #[test]
    fn test_tracer_finish_span_not_found() {
        let tracer = Tracer::new();
        let span = tracer.finish_span(999);
        assert!(span.is_none());
    }

    #[test]
    fn test_tracer_add_metadata() {
        let tracer = Tracer::new();
        let span_id = tracer.start_span("SELECT * FROM users".to_string());
        tracer.add_metadata(span_id, "table".to_string(), "users".to_string());

        let span = tracer.finish_span(span_id);
        assert!(span.is_some());
        assert_eq!(
            span.unwrap().metadata.get("table"),
            Some(&"users".to_string())
        );
    }

    #[test]
    fn test_tracer_add_metadata_invalid_span() {
        let tracer = Tracer::new();
        tracer.add_metadata(999, "key".to_string(), "value".to_string());
    }

    #[test]
    fn test_tracer_multiple_spans() {
        let tracer = Tracer::new();
        let span_id1 = tracer.start_span("SELECT * FROM users".to_string());
        let span_id2 = tracer.start_span("SELECT * FROM orders".to_string());

        tracer.add_metadata(span_id1, "table".to_string(), "users".to_string());
        tracer.add_metadata(span_id2, "table".to_string(), "orders".to_string());

        let span1 = tracer.finish_span(span_id1);
        let span2 = tracer.finish_span(span_id2);

        assert!(span1.is_some());
        assert!(span2.is_some());
        assert_eq!(span1.unwrap().query, "SELECT * FROM users");
        assert_eq!(span2.unwrap().query, "SELECT * FROM orders");
    }

    #[test]
    fn test_tracer_span_id_increment() {
        let tracer = Tracer::new();
        for i in 1..=10 {
            let span_id = tracer.start_span(format!("Query {}", i));
            assert_eq!(span_id, i);
        }
    }

    /// Verifies that lock poisoning recovery (unwrap_or_else + into_inner) works:
    /// a thread panics while holding the lock, then another thread can still proceed.
    #[test]
    fn test_lock_poisoning_recovery() {
        use std::sync::{Arc, Mutex};
        use std::thread;

        let mutex = Arc::new(Mutex::new(42u32));
        let mutex_clone = Arc::clone(&mutex);

        let poison_handle = thread::spawn(move || {
            let _guard = mutex_clone.lock().unwrap();
            panic!("Intentional panic to poison the lock");
        });
        let _ = poison_handle.join();

        let result = mutex.lock();
        assert!(result.is_err(), "Lock should be poisoned");

        let recovered = result.unwrap_or_else(|e| e.into_inner());
        assert_eq!(*recovered, 42, "Recovered value should match");
    }
}

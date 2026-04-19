//! A3 — Spans must be finished even when the body returns early with `?`.
//! `SpanGuard` provides RAII semantics so spans cannot leak.

use odbc_engine::observability::{SpanGuard, Tracer};
use std::sync::Arc;

#[test]
fn span_guard_finishes_span_on_drop() {
    let tracer = Arc::new(Tracer::new());
    let active_before = tracer.active_span_count();
    {
        let _g = SpanGuard::new(Arc::clone(&tracer), "select 1".to_string());
        assert_eq!(tracer.active_span_count(), active_before + 1);
    }
    assert_eq!(
        tracer.active_span_count(),
        active_before,
        "span must be finished on drop"
    );
}

#[test]
fn span_guard_finishes_span_on_panic_unwind() {
    let tracer = Arc::new(Tracer::new());
    let tracer_clone = Arc::clone(&tracer);
    let active_before = tracer.active_span_count();
    let r = std::panic::catch_unwind(move || {
        let _g = SpanGuard::new(tracer_clone, "select 1".to_string());
        panic!("simulated failure mid-query");
    });
    assert!(r.is_err());
    assert_eq!(
        tracer.active_span_count(),
        active_before,
        "span must be finished even on panic unwind"
    );
}

#[test]
fn span_guard_can_be_finished_explicitly() {
    let tracer = Arc::new(Tracer::new());
    let g = SpanGuard::new(Arc::clone(&tracer), "select 1".to_string());
    let span = g.finish();
    assert!(span.is_some(), "explicit finish returns the span");
    assert_eq!(tracer.active_span_count(), 0);
}

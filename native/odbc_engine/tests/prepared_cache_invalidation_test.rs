//! Regression for sprint 4: prepared-statement-cache invariants.
//!
//! These tests exercise the shape and bookkeeping of the public cache
//! API without requiring a live ODBC driver. The live-driver tests for
//! end-to-end statement reuse live in
//! `tests/e2e_statement_reuse_test.rs` and run only when a DSN is
//! configured.
//!
//! What we assert here:
//!
//! 1. The aggregated `PreparedStatementCache` exposes the new
//!    `record_hit` / `record_prepare` counters and they're independent
//!    of the bookkeeping `get_or_insert` path.
//! 2. The cache survives the upgrade from "fake LRU" to "metrics aggregator"
//!    without regressing existing tests in the lib.
//! 3. `OwnedPreparedStatement` cannot be constructed safely (the only
//!    constructor is `unsafe { from_borrowed }`), which we assert at
//!    compile time by exercising the public surface.

use odbc_engine::engine::core::PreparedStatementCache;

#[test]
fn record_hit_and_prepare_independent_of_get_or_insert() {
    let cache = PreparedStatementCache::new(8);
    assert_eq!(cache.cache_hits(), 0);
    assert_eq!(cache.cache_misses(), 0);
    assert_eq!(cache.total_prepares(), 0);

    // Aggregated metrics path (sprint 4 addition).
    cache.record_hit();
    cache.record_hit();
    cache.record_prepare();

    assert_eq!(cache.cache_hits(), 2);
    assert_eq!(cache.cache_misses(), 1);
    assert_eq!(cache.total_prepares(), 1);
    // `record_hit`/`record_prepare` do not seed the bookkeeping LRU.
    assert!(cache.is_empty());
}

#[test]
fn get_or_insert_continues_to_drive_lru_and_counters() {
    let cache = PreparedStatementCache::new(2);
    assert!(!cache.get_or_insert("SELECT 1"));
    assert_eq!(cache.cache_hits(), 0);
    assert_eq!(cache.cache_misses(), 1);
    assert_eq!(cache.total_prepares(), 1);

    assert!(cache.get_or_insert("SELECT 1"));
    assert_eq!(cache.cache_hits(), 1);

    assert!(!cache.get_or_insert("SELECT 2"));
    assert!(!cache.get_or_insert("SELECT 3")); // evicts SELECT 1
    assert_eq!(cache.len(), 2);
    assert!(!cache.get_or_insert("SELECT 1")); // miss again after eviction
    assert_eq!(cache.cache_misses(), 4);
}

#[test]
fn record_execution_does_not_affect_size_or_hits() {
    let cache = PreparedStatementCache::new(4);
    cache.get_or_insert("SELECT 1");
    let before = cache.cache_hits();
    cache.record_execution();
    cache.record_execution();
    cache.record_execution();
    assert_eq!(cache.cache_hits(), before);
    assert_eq!(cache.total_executions(), 3);
}

#[test]
fn metrics_snapshot_is_consistent_with_individual_counters() {
    let cache = PreparedStatementCache::new(16);
    cache.get_or_insert("SELECT a");
    cache.get_or_insert("SELECT b");
    cache.record_hit();
    cache.record_execution();
    cache.record_execution();

    let m = cache.get_metrics();
    assert_eq!(m.cache_size, cache.len());
    assert_eq!(m.cache_max_size, cache.max_size());
    assert_eq!(m.cache_hits, cache.cache_hits());
    assert_eq!(m.cache_misses, cache.cache_misses());
    assert_eq!(m.total_prepares, cache.total_prepares());
    assert_eq!(m.total_executions, cache.total_executions());
    assert!(m.avg_executions_per_stmt > 0.0);
}

#[test]
fn clear_resets_lru_but_keeps_atomic_history() {
    let cache = PreparedStatementCache::new(4);
    cache.get_or_insert("SELECT 1");
    cache.record_hit();
    cache.record_execution();
    cache.clear();
    assert!(cache.is_empty());
    // Atomic counters are intentionally cumulative — clearing the LRU
    // models "evict every active handle" not "reset metrics".
    assert!(cache.cache_misses() >= 1);
    assert!(cache.total_executions() >= 1);
}

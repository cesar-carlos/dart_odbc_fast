//! Sharded FFI state.
//!
//! Sprint 3 of the engine-perf plan. The conservative split moves the
//! categories with the highest write-contention out of the monolithic
//! `Mutex<GlobalState>` into their own per-category locks (or atomics /
//! lock-free `Arc`s for immutables). Goals:
//!
//! - `metrics` and `audit_logger` are immutable after init → live in
//!   `OnceLock<Arc<_>>` and are accessed without ever taking a lock.
//! - `connection_errors` is read on **every** poll and written on every
//!   failed query → moves to its own [`std::sync::RwLock`] so readers
//!   don't block writers operating on unrelated categories.
//! - `async_requests` is a self-contained subsystem; moves to its own
//!   [`std::sync::Mutex`] so polling an async request id does not block
//!   query execution or vice-versa.
//! - `streams` maps moved to [`streams`] (sprint 4 follow-up) so poll/fetch
//!   no longer contend on the outer `GlobalState` mutex.
//! - `connections` moved to [`connections`] (sprint 4 follow-up) so
//!   read-mostly connection lookups no longer require the outer mutex.
//!
//! The remaining maps (`pools`, `transactions`, `xa_*`, `statements`)
//! stay inside `GlobalState` for now: they need atomic transitions
//! (e.g. removing a connection must also remove its open transactions).
//!
//! ## Lock ordering
//!
//! When more than one of the locks below is held in the same scope, the
//! canonical order to avoid deadlock is:
//!
//! 1. `GLOBAL_STATE` (the residual outer mutex on `GlobalState`).
//! 2. [`connections::connections_write`] / [`connections::connections_read`]
//!    (dedicated `RwLock` for regular connections; write after outer when
//!    both are needed, e.g. disconnect cleanup).
//! 3. [`streams::try_lock_stream_maps`].
//! 4. [`async_requests_lock`].
//! 5. [`connection_errors_lock`] (write side first, then read side if
//!    promoted; never downgrade-then-reacquire while holding (1)).
//!
//! Immutable accessors ([`ffi_metrics`], [`ffi_audit_logger`]) never lock
//! and may be called at any point in any order.

mod connections;
mod streams;

pub use connections::contains_connection;
pub(crate) use connections::{connection_handles, insert_connection, remove_connection};
pub(crate) use streams::{
    allocate_stream_id, cancel_streams_for_connection, close_stream, insert_stream,
    reinsert_stream, remove_stream, request_stream_cancel, stream_connection_id, with_stream_mut,
};

use std::collections::HashMap;
use std::sync::{Arc, OnceLock, RwLock, RwLockReadGuard, RwLockWriteGuard};
use std::time::Instant;

use crate::error::StructuredError;
use crate::observability::Metrics;
use crate::security::AuditLogger;

/// Legacy global FFI error state — kept for functions without a
/// `conn_id` context (`odbc_get_error`, `odbc_get_structured_error`).
///
/// Sprint 4 follow-up A2 split this out of `GlobalState` so legacy
/// error reads (a common Dart-side polling pattern after a failed
/// call) no longer require the outer mutex used by query execution.
/// Writers (`set_connection_error`, internal init failure paths)
/// take the write side; readers (`odbc_get_error*`) take the read
/// side and can proceed concurrently with most FFI traffic.
#[derive(Default)]
pub struct LegacyGlobalError {
    pub message: Option<String>,
    pub structured: Option<StructuredError>,
}

/// Per-connection FFI error slot (mirrors the historical
/// `ConnectionError` struct that used to live in `ffi/mod.rs`).
#[derive(Debug, Clone)]
pub struct ConnectionError {
    pub simple_message: String,
    pub structured: Option<StructuredError>,
    #[allow(
        dead_code,
        reason = "Reserved for error expiration/TTL; ODBC-ENG-422; remove by 2026-09-30."
    )]
    pub timestamp: Instant,
}

impl ConnectionError {
    pub fn new(message: String) -> Self {
        Self {
            simple_message: message,
            structured: None,
            timestamp: Instant::now(),
        }
    }

    pub fn from_structured(error: StructuredError) -> Self {
        Self {
            simple_message: error.message.clone(),
            structured: Some(error),
            timestamp: Instant::now(),
        }
    }
}

// --- Immutables (initialised once, accessed lock-free) ----------------------

static METRICS: OnceLock<Arc<Metrics>> = OnceLock::new();
static AUDIT_LOGGER: OnceLock<Arc<AuditLogger>> = OnceLock::new();

/// Returns the process-wide [`Metrics`] handle. Always succeeds — the
/// metrics struct is created on first access. Cheap (no lock).
pub fn ffi_metrics() -> Arc<Metrics> {
    Arc::clone(METRICS.get_or_init(|| Arc::new(Metrics::new())))
}

/// Returns the process-wide [`AuditLogger`]. Created disabled-by-default
/// on first access; callers that need it enabled use the existing
/// `audit_*` FFI entry points which interact through this singleton.
pub fn ffi_audit_logger() -> Arc<AuditLogger> {
    Arc::clone(AUDIT_LOGGER.get_or_init(|| Arc::new(AuditLogger::new(false))))
}

// --- Per-connection error map (own RwLock) ----------------------------------

type ErrorMap = HashMap<u32, ConnectionError>;

fn connection_errors() -> &'static RwLock<ErrorMap> {
    static MAP: OnceLock<RwLock<ErrorMap>> = OnceLock::new();
    MAP.get_or_init(|| RwLock::new(HashMap::new()))
}

/// Acquire the read side of the connection-error map. Returns `None`
/// when the lock is poisoned (treated by FFI guards as an internal
/// error, same as the previous `try_lock` pattern). Poison is logged
/// at `error` level so silent diagnostic loss can be detected.
pub fn connection_errors_read() -> Option<RwLockReadGuard<'static, ErrorMap>> {
    match connection_errors().read() {
        Ok(guard) => Some(guard),
        Err(poisoned) => {
            log::error!(
                "ffi::state::connection_errors RwLock read poisoned: a previous writer panicked \
                 while holding the lock; per-connection errors will be unavailable until the \
                 process restarts ({poisoned})"
            );
            None
        }
    }
}

/// Acquire the write side of the connection-error map. See
/// [`connection_errors_read`] for the poison policy.
pub fn connection_errors_write() -> Option<RwLockWriteGuard<'static, ErrorMap>> {
    match connection_errors().write() {
        Ok(guard) => Some(guard),
        Err(poisoned) => {
            log::error!(
                "ffi::state::connection_errors RwLock write poisoned: a previous writer panicked \
                 while holding the lock; subsequent set_connection_error calls will silently \
                 drop until the process restarts ({poisoned})"
            );
            None
        }
    }
}

/// Record a plain message for `conn_id`.
pub fn set_connection_error(conn_id: u32, message: String) {
    if let Some(mut map) = connection_errors_write() {
        map.insert(conn_id, ConnectionError::new(message));
    }
}

/// Record a structured error for `conn_id`.
pub fn set_connection_structured_error(conn_id: u32, error: StructuredError) {
    if let Some(mut map) = connection_errors_write() {
        map.insert(conn_id, ConnectionError::from_structured(error));
    }
}

/// Fetch the recorded message for `conn_id` if any.
pub fn get_connection_error_message(conn_id: u32) -> Option<String> {
    connection_errors_read().and_then(|m| m.get(&conn_id).map(|e| e.simple_message.clone()))
}

/// Fetch the recorded [`StructuredError`] for `conn_id` if any.
pub fn get_connection_structured_error(conn_id: u32) -> Option<StructuredError> {
    connection_errors_read().and_then(|m| m.get(&conn_id).and_then(|e| e.structured.clone()))
}

/// Drop the error slot for `conn_id` (used when a connection is closed).
pub fn clear_connection_error(conn_id: u32) {
    if let Some(mut map) = connection_errors_write() {
        map.remove(&conn_id);
    }
}

// --- Legacy global error (own RwLock) ---------------------------------------

fn legacy_error_lock() -> &'static RwLock<LegacyGlobalError> {
    static SLOT: OnceLock<RwLock<LegacyGlobalError>> = OnceLock::new();
    SLOT.get_or_init(|| RwLock::new(LegacyGlobalError::default()))
}

/// Acquire a read guard on the legacy global error slot. Returns
/// `None` on poison (logged).
pub fn legacy_global_error_read() -> Option<RwLockReadGuard<'static, LegacyGlobalError>> {
    match legacy_error_lock().read() {
        Ok(guard) => Some(guard),
        Err(poisoned) => {
            log::error!(
                "ffi::state::legacy_global_error RwLock read poisoned: a previous writer panicked \
                 while holding the lock; legacy error inspection will return None until process \
                 restart ({poisoned})"
            );
            None
        }
    }
}

/// Acquire a write guard on the legacy global error slot.
pub fn legacy_global_error_write() -> Option<RwLockWriteGuard<'static, LegacyGlobalError>> {
    match legacy_error_lock().write() {
        Ok(guard) => Some(guard),
        Err(poisoned) => {
            log::error!(
                "ffi::state::legacy_global_error RwLock write poisoned: a previous writer \
                 panicked while holding the lock; legacy error writes will be dropped until \
                 process restart ({poisoned})"
            );
            None
        }
    }
}

/// Convenience setter for the plain-message side of the legacy global error.
pub fn set_legacy_global_error(message: String) {
    if let Some(mut guard) = legacy_global_error_write() {
        guard.message = Some(message);
        guard.structured = None;
    }
}

/// Convenience setter for the structured side of the legacy global error.
pub fn set_legacy_global_structured_error(error: StructuredError) {
    if let Some(mut guard) = legacy_global_error_write() {
        guard.message = Some(error.message.clone());
        guard.structured = Some(error);
    }
}

/// Read the legacy global error message, defaulting to `"No error"` to
/// preserve the historical FFI contract.
pub fn legacy_global_error_message() -> String {
    legacy_global_error_read()
        .and_then(|g| g.message.clone())
        .unwrap_or_else(|| "No error".to_string())
}

/// Read the legacy global structured error.
pub fn legacy_global_structured_error() -> Option<StructuredError> {
    legacy_global_error_read().and_then(|g| g.structured.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[serial_test::serial]
    fn metrics_singleton_is_stable_across_calls() {
        let a = ffi_metrics();
        let b = ffi_metrics();
        assert!(Arc::ptr_eq(&a, &b));
    }

    #[test]
    #[serial_test::serial]
    fn audit_logger_singleton_is_stable_across_calls() {
        let a = ffi_audit_logger();
        let b = ffi_audit_logger();
        assert!(Arc::ptr_eq(&a, &b));
    }

    #[test]
    #[serial_test::serial]
    fn connection_error_round_trip_plain_message() {
        let conn_id = 1_000_001;
        set_connection_error(conn_id, "boom".to_string());
        assert_eq!(
            get_connection_error_message(conn_id).as_deref(),
            Some("boom")
        );
        clear_connection_error(conn_id);
        assert!(get_connection_error_message(conn_id).is_none());
    }

    #[test]
    #[serial_test::serial]
    fn connection_error_round_trip_structured() {
        let conn_id = 1_000_002;
        let structured = StructuredError {
            sqlstate: [b'4', b'2', b'S', b'0', b'2'],
            native_code: 12345,
            message: "missing table".to_string(),
        };
        set_connection_structured_error(conn_id, structured.clone());
        let recovered = get_connection_structured_error(conn_id).expect("structured present");
        assert_eq!(recovered.sqlstate, structured.sqlstate);
        assert_eq!(recovered.native_code, structured.native_code);
        assert_eq!(recovered.message, structured.message);
        // Simple-message side mirrors the structured payload.
        assert_eq!(
            get_connection_error_message(conn_id).as_deref(),
            Some("missing table")
        );
        clear_connection_error(conn_id);
    }

    #[test]
    #[serial_test::serial]
    fn structured_error_overwrites_simple_for_same_conn_id() {
        let conn_id = 1_000_003;
        set_connection_error(conn_id, "old".to_string());
        let structured = StructuredError {
            sqlstate: [b'2', b'2', b'P', b'0', b'2'],
            native_code: 1,
            message: "new".to_string(),
        };
        set_connection_structured_error(conn_id, structured);
        assert_eq!(
            get_connection_error_message(conn_id).as_deref(),
            Some("new")
        );
        clear_connection_error(conn_id);
    }

    /// Mirrors [`connection_errors_read`] / [`connection_errors_write`] poison
    /// policy without poisoning the process-wide `OnceLock` (parallel lib tests
    /// would otherwise observe `None` and fail).
    #[test]
    fn connection_errors_read_returns_none_when_lock_poisoned() {
        let lock = RwLock::new(HashMap::<u32, ConnectionError>::new());
        let poisoned = std::panic::catch_unwind(|| {
            let _guard = lock.write().expect("lock should be available");
            panic!("intentional panic to poison local RwLock");
        });
        assert!(poisoned.is_err(), "panic should poison the RwLock");

        assert!(
            lock.read().ok().is_none(),
            "poisoned connection_errors read should return None for FFI guards"
        );
        assert!(
            lock.write().ok().is_none(),
            "poisoned connection_errors write should return None for FFI guards"
        );
    }

    /// Mirrors [`legacy_global_error_read`] / [`legacy_global_error_write`]
    /// poison policy on a local stand-in lock (see comment on the test above).
    #[test]
    fn legacy_global_error_read_returns_none_when_lock_poisoned() {
        let lock = RwLock::new(LegacyGlobalError::default());
        let poisoned = std::panic::catch_unwind(|| {
            let _guard = lock.write().expect("lock should be available");
            panic!("intentional panic to poison local RwLock");
        });
        assert!(poisoned.is_err(), "panic should poison the RwLock");

        assert!(
            lock.read().ok().is_none(),
            "poisoned legacy error read should return None"
        );
        assert!(
            lock.write().ok().is_none(),
            "poisoned legacy error write should return None"
        );
    }
}

// The FFI's `AsyncRequestManager` lives in `ffi/mod.rs` because it owns
// types (`AsyncRequestSlot`) that are tightly coupled to the C ABI
// surface. To break the cyclic dependency it would impose here, the
// dedicated `Mutex<AsyncRequestManager>` lives in that module and is
// accessed directly from there. The split is the same — async polls no
// longer block on the outer `GlobalState` mutex — only the implementation
// detail of where the static lives differs.

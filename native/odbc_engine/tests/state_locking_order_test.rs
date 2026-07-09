//! Regression test for sprint 3 lock ordering.
//!
//! Canonical order (documented in `ffi/state/mod.rs`):
//!
//! 1. `GLOBAL_STATE` (residual outer Mutex on `GlobalState`: env)
//! 2. XA maps (`ffi::state::xa`)
//! 3. Transaction maps (`ffi::state::transactions`)
//! 4. Pool maps (`ffi::state::pools`)
//! 5. Connection registry (`ffi::state::connections`)
//! 6. Stream maps (`ffi::state::streams`)
//! 7. Statement maps (`ffi::state::statements`)
//! 8. `ASYNC_REQUESTS` (own Mutex)
//! 9. `connection_errors` (own RwLock)
//! 10. Metadata cache (`ffi::state` metadata helpers)
//!
//! Immutable accessors (`ffi_metrics`, `ffi_audit_logger`) never lock and
//! may interleave at any point.
//!
//! These tests cannot construct a real `GlobalState` from outside the
//! crate, so they exercise the **public** state-module helpers under
//! concurrent load and assert that they never deadlock and never produce
//! poisoned data.

use odbc_engine::ffi::state::{
    clear_connection_error, contains_connection, ffi_audit_logger, ffi_metrics,
    get_connection_error_message, get_connection_structured_error, legacy_global_error_message,
    legacy_global_error_write, legacy_global_structured_error, set_connection_error,
    set_connection_structured_error, set_legacy_global_error, set_legacy_global_structured_error,
};
use odbc_engine::StructuredError;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

#[test]
fn connection_registry_reads_do_not_deadlock_under_contention() {
    const THREADS: usize = 4;
    const LOOKUPS: usize = 500;
    let handles: Vec<_> = (0..THREADS)
        .map(|t| {
            thread::spawn(move || {
                for i in 0..LOOKUPS {
                    let conn_id = 20_000 + (t as u32) * 1000 + (i as u32);
                    let _ = contains_connection(conn_id);
                }
            })
        })
        .collect();
    for h in handles {
        h.join().expect("connection lookup thread");
    }
}

#[test]
fn concurrent_error_writes_never_deadlock_or_corrupt() {
    const THREADS: usize = 8;
    const WRITES_PER_THREAD: usize = 200;
    let handles: Vec<_> = (0..THREADS)
        .map(|t| {
            thread::spawn(move || {
                for i in 0..WRITES_PER_THREAD {
                    let conn_id = 10_000 + (t as u32) * 1000 + (i as u32);
                    if i % 3 == 0 {
                        set_connection_error(conn_id, format!("thread {t} iter {i}"));
                    } else {
                        let structured = StructuredError {
                            sqlstate: [b'4', b'2', b'P', b'0', b'1'],
                            native_code: t as i32,
                            message: format!("structured {t}/{i}"),
                        };
                        set_connection_structured_error(conn_id, structured);
                    }
                }
            })
        })
        .collect();
    for h in handles {
        h.join().expect("worker thread");
    }

    // Spot-check several known conn ids resolved consistently.
    for t in 0..THREADS {
        let conn_id = 10_000 + (t as u32) * 1000 + 1; // i=1 → structured
        let recovered = get_connection_structured_error(conn_id).expect("structured present");
        assert_eq!(recovered.native_code, t as i32);
        assert!(recovered.message.starts_with("structured "));

        clear_connection_error(conn_id);
    }
}

#[test]
fn readers_do_not_block_writers() {
    let conn_id = 99_999;
    set_connection_error(conn_id, "initial".to_string());

    let reader_count = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));

    let mut handles = Vec::new();
    for _ in 0..4 {
        let counter = Arc::clone(&reader_count);
        let stop_flag = Arc::clone(&stop);
        handles.push(thread::spawn(move || {
            while !stop_flag.load(std::sync::atomic::Ordering::Relaxed) {
                if get_connection_error_message(conn_id).is_some() {
                    counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
            }
        }));
    }

    for i in 0..50 {
        set_connection_error(conn_id, format!("update {i}"));
        thread::sleep(Duration::from_micros(10));
    }
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    for h in handles {
        h.join().expect("reader thread");
    }

    let reads = reader_count.load(std::sync::atomic::Ordering::Relaxed);
    assert!(
        reads > 0,
        "readers should have observed values under contention"
    );
    clear_connection_error(conn_id);
}

#[test]
fn immutables_are_lock_free_singletons() {
    let m1 = ffi_metrics();
    let m2 = ffi_metrics();
    assert!(Arc::ptr_eq(&m1, &m2));

    let a1 = ffi_audit_logger();
    let a2 = ffi_audit_logger();
    assert!(Arc::ptr_eq(&a1, &a2));
}

#[test]
fn clear_connection_error_is_idempotent() {
    let conn_id = 77_777;
    clear_connection_error(conn_id);
    assert!(get_connection_error_message(conn_id).is_none());
    set_connection_error(conn_id, "boom".to_string());
    clear_connection_error(conn_id);
    clear_connection_error(conn_id);
    assert!(get_connection_error_message(conn_id).is_none());
}

// ------------------------------------------------------------------
// Sprint 4 follow-up A2 — legacy global error split.
//
// The legacy `state.last_error` / `state.last_structured_error` fields
// moved out of `GlobalState` into their own `RwLock`. These tests pin
// the new helpers' behaviour so future PRs that touch the migration
// path cannot silently regress to the old in-`GlobalState` storage.
// ------------------------------------------------------------------

#[test]
fn legacy_error_message_round_trip() {
    // Snapshot/restore to keep test isolation (the slot is process-wide).
    let prev_message;
    let prev_structured;
    {
        let mut guard = legacy_global_error_write().expect("write lock");
        prev_message = guard.message.clone();
        prev_structured = guard.structured.clone();
        guard.message = None;
        guard.structured = None;
    }

    set_legacy_global_error("plain".to_string());
    assert_eq!(legacy_global_error_message(), "plain");
    assert!(legacy_global_structured_error().is_none());

    {
        let mut guard = legacy_global_error_write().expect("write lock");
        guard.message = prev_message;
        guard.structured = prev_structured;
    }
}

#[test]
fn legacy_structured_error_overwrites_plain_message() {
    let prev_message;
    let prev_structured;
    {
        let mut guard = legacy_global_error_write().expect("write lock");
        prev_message = guard.message.clone();
        prev_structured = guard.structured.clone();
        guard.message = None;
        guard.structured = None;
    }

    set_legacy_global_error("plain".to_string());
    let structured = StructuredError {
        sqlstate: [b'0', b'1', b'0', b'0', b'0'],
        native_code: 1,
        message: "structured".to_string(),
    };
    set_legacy_global_structured_error(structured.clone());

    // After a structured write, both the plain message and the
    // structured payload track the new error.
    assert_eq!(legacy_global_error_message(), "structured");
    let recovered = legacy_global_structured_error().expect("structured present");
    assert_eq!(recovered.sqlstate, structured.sqlstate);
    assert_eq!(recovered.native_code, structured.native_code);
    assert_eq!(recovered.message, structured.message);

    {
        let mut guard = legacy_global_error_write().expect("write lock");
        guard.message = prev_message;
        guard.structured = prev_structured;
    }
}

#[test]
fn legacy_error_message_defaults_to_no_error_string() {
    let prev_message;
    let prev_structured;
    {
        let mut guard = legacy_global_error_write().expect("write lock");
        prev_message = guard.message.clone();
        prev_structured = guard.structured.clone();
        guard.message = None;
        guard.structured = None;
    }

    assert_eq!(legacy_global_error_message(), "No error");

    {
        let mut guard = legacy_global_error_write().expect("write lock");
        guard.message = prev_message;
        guard.structured = prev_structured;
    }
}

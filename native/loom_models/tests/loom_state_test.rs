//! Loom models for the sprint 3 FFI state split.
//!
//! Run:
//!
//! ```bash
//! RUSTFLAGS="--cfg loom" cargo test -p loom_models --release -- --test-threads=1
//! ```
//!
//! Lives in the dedicated `loom_models` workspace member because the
//! parent crate `odbc_engine` depends on `tokio`, and `tokio` cannot be
//! compiled with `--cfg loom` (its `AtomicWaker` exports are gated
//! behind `#[cfg(not(loom))]` while `task::local` uses them
//! unconditionally — see <https://github.com/tokio-rs/tokio/issues/2510>).
//! Building loom in this isolated crate avoids dragging `tokio` into the
//! `--cfg loom` build.
//!
//! Loom is significantly more expensive than the empirical
//! `std::thread` tests in `odbc_engine/tests/state_locking_order_test.rs`;
//! the release build keeps wall-clock manageable. The three models
//! below mirror the highest-traffic interactions in
//! `odbc_engine::ffi::state::*` and the residual outer mutex on
//! `GlobalState`:
//!
//! 1. **`connection_errors` interleavings** — concurrent writers and
//!    readers on the per-connection error `RwLock`. Loom must not
//!    discover a state where a write is lost or a read observes a
//!    torn intermediate.
//! 2. **Lock-order interactions** — one thread acquires the outer
//!    mutex then the `connection_errors` `RwLock`; another thread
//!    acquires only `connection_errors`. Loom verifies there is no
//!    cycle that would deadlock.
//! 3. **Immutable `Arc` singleton visibility** — two threads observe
//!    the same `Arc<T>` lock-free, modeling the `state::ffi_metrics()`
//!    / `state::ffi_audit_logger()` hot path.
//!
//! The models intentionally do NOT import `odbc_engine::ffi::state`
//! directly because loom requires its own `loom::sync` primitives; the
//! production types use `std::sync` and would not be intercepted by the
//! loom scheduler.
//!
//! When loom is not enabled at compile time (the default for the
//! library target), the file compiles as an empty integration test —
//! `cargo test -p loom_models` without `--cfg loom` is a no-op.

// `loom` is a custom cfg gated by `RUSTFLAGS="--cfg loom"` per the
// loom crate's documented invocation pattern. It is not in Cargo's
// known-cfg list so the lint would warn on every build.
#![allow(unexpected_cfgs)]
#![cfg(loom)]

use loom::sync::{Arc, Mutex, RwLock};
use loom::thread;

#[derive(Default)]
struct ErrorMap {
    by_id: std::collections::HashMap<u32, String>,
}

#[test]
fn errors_writer_reader_interleaving_never_loses_writes() {
    loom::model(|| {
        let errors = Arc::new(RwLock::new(ErrorMap::default()));

        let w = {
            let errors = Arc::clone(&errors);
            thread::spawn(move || {
                let mut guard = errors.write().unwrap();
                guard.by_id.insert(1, "boom".to_string());
            })
        };

        let r = {
            let errors = Arc::clone(&errors);
            thread::spawn(move || {
                // Reader may observe the empty map (writer hasn't
                // released yet) or the populated one — both are
                // valid linearisations. The assertion is that
                // neither path returns a corrupted entry.
                let guard = errors.read().unwrap();
                if let Some(v) = guard.by_id.get(&1) {
                    assert_eq!(v, "boom");
                }
            })
        };

        w.join().unwrap();
        r.join().unwrap();

        // Final state must always contain the written value.
        let guard = errors.read().unwrap();
        assert_eq!(guard.by_id.get(&1).map(|s| s.as_str()), Some("boom"));
    });
}

#[test]
fn outer_then_errors_does_not_deadlock_against_errors_only() {
    loom::model(|| {
        let outer = Arc::new(Mutex::new(0u32));
        let errors = Arc::new(RwLock::new(ErrorMap::default()));

        // Thread A: outer -> errors (canonical lock order).
        let t1 = {
            let outer = Arc::clone(&outer);
            let errors = Arc::clone(&errors);
            thread::spawn(move || {
                let _outer_guard = outer.lock().unwrap();
                let mut errs = errors.write().unwrap();
                errs.by_id.insert(1, "from_t1".to_string());
            })
        };

        // Thread B: errors only. No risk of cycle because it never
        // tries to acquire `outer` while holding `errors`.
        let t2 = {
            let errors = Arc::clone(&errors);
            thread::spawn(move || {
                let _errs = errors.read().unwrap();
            })
        };

        t1.join().unwrap();
        t2.join().unwrap();
    });
}

#[test]
fn arc_metrics_singleton_is_observed_by_every_thread() {
    loom::model(|| {
        let metrics = Arc::new(0u64);

        // Two threads clone the immutable Arc. Loom should observe
        // both witnessing the same allocation.
        let m1 = Arc::clone(&metrics);
        let m2 = Arc::clone(&metrics);

        let t1 = thread::spawn(move || {
            // Lock-free read of the immutable value.
            assert_eq!(*m1, 0);
        });

        let t2 = thread::spawn(move || {
            assert_eq!(*m2, 0);
        });

        t1.join().unwrap();
        t2.join().unwrap();
    });
}

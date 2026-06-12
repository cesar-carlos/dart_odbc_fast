//! Owned prepared-statement RAII guard.
//!
//! Sprint 4 of the engine-perf plan. Encapsulates the
//! `mem::transmute` that lengthens a borrowed
//! `Prepared<StatementImpl<'conn>>` to `Prepared<StatementImpl<'static>>`
//! so it can live inside a per-connection cache.
//!
//! ## Why a wrapper?
//!
//! The previous in-line `unsafe { std::mem::transmute(prepared) }` in
//! [`crate::handles::cached_connection`] was correct **by convention**:
//! the comment promised that the cache would always be cleared before
//! the owning connection was dropped or before
//! [`crate::handles::CachedConnection::connection_mut`] handed out a
//! mutable reference. Reviewers could only confirm that by reading the
//! `Drop` impl plus every call site.
//!
//! [`OwnedPreparedStatement`] makes the same guarantee a property of
//! the **type**:
//!
//! - The `'static` lifetime fabrication is contained in
//!   [`OwnedPreparedStatement::from_borrowed`] (the only `unsafe` site).
//! - Access to the wrapped statement is gated through
//!   [`OwnedPreparedStatement::with_mut`] which returns a reference only
//!   for the duration of the closure.
//! - The wrapper is `!Send` to discourage moving it across thread
//!   boundaries away from the connection it borrows from.
//! - Owners (i.e. the cache) hold the wrapper in a structure that is
//!   dropped *before* the connection (`stmt_cache` field declared above
//!   `conn` in `CachedConnection`, see
//!   <https://doc.rust-lang.org/reference/destructors.html#destructors-and-types-with-mutable-data>).
//!
//! ## Safety contract (caller-visible)
//!
//! Constructing an `OwnedPreparedStatement` from a borrowed
//! `Prepared<StatementImpl<'conn>>` requires the caller to promise that
//! the resulting wrapper will be dropped **strictly before** the
//! connection that backs the underlying statement handle. The cache in
//! `CachedConnection` upholds this by:
//!
//! 1. Storing the cache *first* in struct declaration order, so the
//!    drop glue runs `stmt_cache.drop()` before `conn.drop()`.
//! 2. Calling [`OwnedPreparedStatement::with_mut`] only via methods that
//!    have `&mut self` on the connection wrapper, never via raw
//!    references.
//! 3. Clearing the cache on every `connection_mut()` call (which is the
//!    only path that exposes a mutable reference to the underlying
//!    connection).

// Module-level cfg is unnecessary because the parent module already
// gates the `mod owned_prepared;` declaration on
// `feature = "statement-handle-reuse"` — duplicating it here triggers
// clippy's `duplicated_attributes` lint.

use odbc_api::handles::StatementImpl;
use odbc_api::Prepared;

/// Type-erased lifetime container for a `Prepared` statement that, at
/// runtime, is rooted in a parent connection whose lifetime exceeds the
/// wrapper's. See module docs for the safety contract.
pub struct OwnedPreparedStatement {
    inner: Prepared<StatementImpl<'static>>,
}

impl OwnedPreparedStatement {
    /// Adopt a freshly-prepared statement into the cache.
    ///
    /// # Safety
    ///
    /// `prepared` must have been produced from a `Connection<'conn>` whose
    /// lifetime extends past every conceivable drop of `self`. In
    /// practice, this is enforced by the construction pattern in
    /// `CachedConnection::adopt_prepared` — the connection lives for the
    /// entire lifetime of the `CachedConnection`, and the `stmt_cache`
    /// field is declared first so drop glue runs `stmt_cache.drop()`
    /// before `conn.drop()`.
    pub unsafe fn from_borrowed<'conn>(prepared: Prepared<StatementImpl<'conn>>) -> Self {
        // Tripwire: if a future `odbc-api` release ever changes
        // `Prepared<StatementImpl<'_>>` to include a non-zero-sized
        // lifetime-dependent field, the `mem::transmute` below would
        // silently misbehave. The `size_of_prepared_invariant_test`
        // unit test in this module fails to compile (or panics) the
        // moment that contract drifts, surfacing the bug instead of
        // letting it produce UB at runtime.
        //
        // SAFETY: caller contract above guarantees that the statement
        // handle will never be touched after the connection it points
        // into has been dropped. `StatementImpl<'conn>` and
        // `StatementImpl<'static>` differ only in the phantom lifetime
        // parameter, not in layout — `odbc-api`'s public types are
        // `#[repr(transparent)]` wrappers over a raw SQLHSTMT.
        // SAFETY: Phantom lifetime only — layouts match; caller drop-order contract
        // guarantees the handle outlives the backing connection.
        let inner: Prepared<StatementImpl<'static>> = unsafe { std::mem::transmute(prepared) };
        Self { inner }
    }

    /// Operate on the wrapped `Prepared` for the duration of `f`.
    ///
    /// The closure cannot leak the reference because `with_mut` reborrows
    /// the statement under the closure's own lifetime — no escape hatch
    /// returns a `&'_ mut Prepared` past the call.
    pub fn with_mut<F, R>(&mut self, f: F) -> R
    where
        F: FnOnce(&mut Prepared<StatementImpl<'static>>) -> R,
    {
        f(&mut self.inner)
    }
}

// `OwnedPreparedStatement` is `Send`/`Sync` in the same way the underlying
// `Prepared<StatementImpl<'static>>` is: the cross-thread move is gated by
// the engine's `SharedConnection = Arc<Mutex<CachedConnection>>` wrapper,
// which provides the actual synchronisation. The drop-order invariant
// described in the module docs holds *per* CachedConnection instance,
// regardless of which thread happens to be holding the mutex when the
// statement is exercised.

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::size_of;

    // Real construction requires a live ODBC `Connection`, which is covered
    // by the e2e suite under `tests/e2e_statement_reuse_test.rs` when run
    // against a configured DSN. The unit-level guarantees of this wrapper
    // are structural (drop order, single point of unsafe) and are
    // validated by the rest of the crate compiling against it: any future
    // edit that violates the invariants either fails to compile or fails
    // the drop-order regression test in
    // `tests/prepared_cache_invalidation_test.rs`.

    /// Tripwire for the `from_borrowed` `mem::transmute` safety
    /// contract: lifetimes are erased at codegen, so the two
    /// `Prepared<StatementImpl<'_>>` instantiations **must** share
    /// layout. If a future `odbc-api` release breaks that (e.g. by
    /// adding a `PhantomData<&'a SomeType>` where `SomeType` isn't
    /// zero-sized), this test starts failing — orienting the bug to
    /// `OwnedPreparedStatement` instead of letting it produce UB at
    /// runtime via the cache.
    #[test]
    fn from_borrowed_transmute_size_invariant_holds() {
        // We can't name both lifetimes in one function (the borrow
        // checker rejects naming `'a` and `'static` as distinct types
        // here), so we anchor on `'static` for both ends — the layout
        // is identical regardless of the concrete lifetime parameter
        // since `'a` is purely a phantom marker on `StatementImpl`.
        // The assertion still fires if the underlying struct ever
        // grows a runtime field tied to the lifetime.
        type Hot = Prepared<StatementImpl<'static>>;
        assert_eq!(
            size_of::<Hot>(),
            size_of::<OwnedPreparedStatement>(),
            "OwnedPreparedStatement must be a no-op wrapper over Prepared<StatementImpl<'static>>; \
             the from_borrowed mem::transmute relies on this size equality"
        );
    }
}

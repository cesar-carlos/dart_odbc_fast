// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use super::global::*;
use crate::ffi::state;

use crate::engine::{
    IsolationLevel, LockTimeout, SavepointDialect, Transaction, TransactionAccessMode,
};
use crate::error::Result;
use crate::pool::SharedPooledConnection;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_uint};
use std::sync::Arc;

/// Clears begin-in-progress reservation when a begin call returns without an
/// explicit remove (for example transaction-maps re-lock failure).
struct TransactionBeginReservation {
    conn_id: u32,
    armed: bool,
}

impl TransactionBeginReservation {
    fn new(conn_id: u32) -> Self {
        Self {
            conn_id,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for TransactionBeginReservation {
    fn drop(&mut self) {
        if self.armed {
            state::remove_begin_in_progress(self.conn_id);
        }
    }
}

/// Begin a new transaction.
/// conn_id: connection ID from odbc_connect
/// isolation_level: 0=ReadUncommitted, 1=ReadCommitted, 2=RepeatableRead, 3=Serializable
/// savepoint_dialect: 0=Sql92 (SAVEPOINT/ROLLBACK TO SAVEPOINT), 1=SqlServer (SAVE TRANSACTION/ROLLBACK TRANSACTION)
/// Returns: transaction ID (>0) on success, 0 on failure
#[no_mangle]
pub extern "C" fn odbc_transaction_begin(
    conn_id: c_uint,
    isolation_level: c_uint,
    savepoint_dialect: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        // v1 ABI is preserved by delegating to v2 with the safe default
        // access mode (READ WRITE / discriminant 0). v3.x clients that
        // never call v2 keep the exact same wire and behaviour.
        odbc_transaction_begin_v2(conn_id, isolation_level, savepoint_dialect, 0)
    })
}

/// Begin a new transaction with full control over isolation, savepoint
/// dialect AND access mode (`READ ONLY` / `READ WRITE`). Sprint 4.1.
///
/// - `conn_id`: connection ID from `odbc_connect`.
/// - `isolation_level`: `0 = ReadUncommitted`, `1 = ReadCommitted`,
///   `2 = RepeatableRead`, `3 = Serializable`.
/// - `savepoint_dialect`: `0 = Auto` (default; resolved via `SQLGetInfo`),
///   `1 = SqlServer` (`SAVE TRANSACTION`/`ROLLBACK TRANSACTION`),
///   `2 = Sql92` (`SAVEPOINT`/`ROLLBACK TO SAVEPOINT`).
/// - `access_mode`: `0 = ReadWrite` (default), `1 = ReadOnly`. Engines
///   without an equivalent SQL hint (SQL Server, SQLite, Snowflake)
///   silently treat `ReadOnly` as a no-op so callers can program against
///   the abstraction unconditionally.
///
/// Returns the transaction ID (`> 0`) on success, `0` on failure
/// (consult `odbc_get_last_error`). Same allocation and error semantics
/// as [`odbc_transaction_begin`].
#[no_mangle]
pub extern "C" fn odbc_transaction_begin_v2(
    conn_id: c_uint,
    isolation_level: c_uint,
    savepoint_dialect: c_uint,
    access_mode: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        // v2 ABI is preserved by delegating to v3 with the safe default
        // lock-timeout (`0` = engine default). v2 callers that never opt
        // into the timeout get exactly the same behaviour as before.
        odbc_transaction_begin_v3(conn_id, isolation_level, savepoint_dialect, access_mode, 0)
    })
}

/// Begin a new transaction with full control over isolation, savepoint
/// dialect, access mode AND per-transaction lock timeout. Sprint 4.2.
///
/// - `lock_timeout_ms`: `0` = engine default (no override). Any other
///   value is the maximum number of *milliseconds* a statement inside
///   the transaction will wait to acquire a lock before failing with
///   the engine's lock-timeout error. Engines that natively express
///   waits in seconds (MySQL/MariaDB, DB2) round sub-second requests up
///   to 1 second so we never silently relax the bound.
///
/// All other parameters: see [`odbc_transaction_begin_v2`].
///
/// Returns the transaction ID (`> 0`) on success, `0` on failure.
#[no_mangle]
pub extern "C" fn odbc_transaction_begin_v3(
    conn_id: c_uint,
    isolation_level: c_uint,
    savepoint_dialect: c_uint,
    access_mode: c_uint,
    lock_timeout_ms: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        let isolation = match IsolationLevel::from_u32(isolation_level) {
            Some(iso) => iso,
            None => {
                if let Some(mut state) = try_lock_global_state() {
                    set_error(&mut state, "Invalid isolation level".to_string());
                }
                return 0;
            }
        };

        let dialect = SavepointDialect::from_u32(savepoint_dialect);
        let access = TransactionAccessMode::from_u32(access_mode);
        let lock_timeout = LockTimeout::from_millis(lock_timeout_ms);

        enum TransactionBeginSource {
            Regular(crate::handles::SharedHandleManager),
            Pooled(SharedPooledConnection),
        }

        let begin_source = if let Some(handles) = state::connection_handles(conn_id) {
            TransactionBeginSource::Regular(handles)
        } else if let Some(entry) = state::get_pooled_connection(conn_id) {
            TransactionBeginSource::Pooled(entry.pooled)
        } else {
            if let Some(mut gs) = try_lock_global_state() {
                set_connection_error(
                    &mut gs,
                    conn_id,
                    format!("Invalid connection ID: {}", conn_id),
                );
            }
            return 0;
        };

        let reserved = state::with_transaction_maps_mut(|maps| {
            if maps.has_active_for_connection(conn_id) {
                return Err("active");
            }
            if maps.begin_in_progress(conn_id) {
                return Err("begin");
            }
            maps.insert_begin_in_progress(conn_id);
            Ok(())
        });
        match reserved {
            Some(Ok(())) => {}
            Some(Err("active")) => {
                if let Some(mut gs) = try_lock_global_state() {
                    set_connection_error(
                        &mut gs,
                        conn_id,
                        "Connection already has an active transaction".to_string(),
                    );
                }
                return 0;
            }
            Some(Err(_)) => {
                if let Some(mut gs) = try_lock_global_state() {
                    set_connection_error(
                        &mut gs,
                        conn_id,
                        "Transaction begin already in progress for this connection".to_string(),
                    );
                }
                return 0;
            }
            None => return 0,
        }
        let mut begin_reservation = TransactionBeginReservation::new(conn_id);

        // SavepointDialect::Auto resolves via CachedConnection::engine_id
        // (cached SQL_DBMS_NAME) — see v3.1 fix B2 / txn-dialect perf.
        let txn_result = match begin_source {
            TransactionBeginSource::Regular(handles) => Transaction::begin_with_lock_timeout(
                handles,
                conn_id,
                isolation,
                dialect,
                access,
                lock_timeout,
            ),
            TransactionBeginSource::Pooled(pooled) => {
                Transaction::begin_on_pooled_with_lock_timeout(
                    pooled,
                    conn_id,
                    isolation,
                    dialect,
                    access,
                    lock_timeout,
                )
            }
        };

        state::remove_begin_in_progress(conn_id);
        begin_reservation.disarm();
        match txn_result {
            Ok(txn) => {
                let connection_still_valid = state::contains_connection(conn_id)
                    || state::contains_pooled_connection(conn_id);
                if !connection_still_valid {
                    if let Err(e) = txn.rollback() {
                        log::warn!(
                            "Failed to rollback transaction begun on invalidated connection {conn_id}: {e}"
                        );
                    }
                    if let Some(mut gs) = try_lock_global_state() {
                        set_connection_error(
                            &mut gs,
                            conn_id,
                            "Connection became invalid while beginning transaction".to_string(),
                        );
                    }
                    return 0;
                }
                match state::with_transaction_maps_mut(|maps| {
                    if maps.has_active_for_connection(conn_id) {
                        return Err(("active", txn));
                    }
                    maps.allocate_and_insert(txn).map_err(|txn| ("id", txn))
                }) {
                    Some(Ok(id)) => id,
                    Some(Err((reason, txn))) => {
                        if let Err(e) = txn.rollback() {
                            log::warn!(
                                "Failed to rollback transaction after begin registration failure \
                                 on conn_id {conn_id} ({reason}): {e}"
                            );
                        }
                        if let Some(mut gs) = try_lock_global_state() {
                            let msg = if reason == "active" {
                                "Connection already has an active transaction".to_string()
                            } else {
                                "Failed to allocate transaction ID".to_string()
                            };
                            set_connection_error(&mut gs, conn_id, msg);
                        }
                        0
                    }
                    None => 0,
                }
            }
            Err(e) => {
                if let Some(mut gs) = try_lock_global_state() {
                    set_connection_error(
                        &mut gs,
                        conn_id,
                        format!("Failed to begin transaction: {}", e),
                    );
                }
                0
            }
        }
    })
}

/// Re-registers a transaction whose `Arc::try_unwrap` failed because a
/// concurrent savepoint call still holds a clone. Dropping the handle here
/// would let the last clone trigger the `Transaction` auto-rollback `Drop`
/// while the caller believes the transaction still exists; restoring it keeps
/// the registry consistent and makes commit/rollback retryable.
fn restore_busy_transaction(txn_id: c_uint, txn_conn_id: u32, txn_arc: Arc<Transaction>, op: &str) {
    log::warn!(
        "odbc_transaction_{op}: transaction {txn_id} is still referenced (concurrent savepoint \
         in flight); {op} aborted and transaction kept registered for retry"
    );
    state::insert_transaction(txn_id, txn_arc);
    if let Some(mut gs) = try_lock_global_state() {
        set_connection_error(
            &mut gs,
            txn_conn_id,
            format!("Transaction {txn_id} is busy (concurrent savepoint call); retry {op}"),
        );
    }
}

/// Commit a transaction.
/// txn_id: transaction ID from odbc_transaction_begin
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_transaction_commit(txn_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(txn_arc) = state::remove_transaction(txn_id) else {
            if let Some(mut gs) = try_lock_global_state() {
                set_error(&mut gs, format!("Invalid transaction ID: {}", txn_id));
            }
            return 1;
        };
        let txn_conn_id = txn_arc.conn_id();
        let txn = match Arc::try_unwrap(txn_arc) {
            Ok(txn) => txn,
            Err(txn_arc) => {
                // A concurrent savepoint call still holds a clone. Put the
                // handle back so the caller can retry instead of losing the
                // transaction to a Drop auto-rollback.
                restore_busy_transaction(txn_id, txn_conn_id, txn_arc, "commit");
                return 1;
            }
        };
        match txn.commit() {
            Ok(_) => 0,
            Err(e) => {
                if let Some(mut gs) = try_lock_global_state() {
                    set_connection_error(&mut gs, txn_conn_id, format!("Commit failed: {}", e));
                }
                1
            }
        }
    })
}

/// Rollback a transaction.
/// txn_id: transaction ID from odbc_transaction_begin
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_transaction_rollback(txn_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(txn_arc) = state::remove_transaction(txn_id) else {
            if let Some(mut gs) = try_lock_global_state() {
                set_error(&mut gs, format!("Invalid transaction ID: {}", txn_id));
            }
            return 1;
        };
        let txn_conn_id = txn_arc.conn_id();
        let txn = match Arc::try_unwrap(txn_arc) {
            Ok(txn) => txn,
            Err(txn_arc) => {
                // See commit path: keep the transaction registered so the
                // caller can retry once the concurrent user releases it.
                restore_busy_transaction(txn_id, txn_conn_id, txn_arc, "rollback");
                return 1;
            }
        };
        match txn.rollback() {
            Ok(_) => 0,
            Err(e) => {
                if let Some(mut gs) = try_lock_global_state() {
                    set_connection_error(&mut gs, txn_conn_id, format!("Rollback failed: {}", e));
                }
                1
            }
        }
    })
}

/// Generic dispatcher for the three savepoint FFI entry points.
///
/// All paths go through `Transaction::savepoint_*` which performs identifier
/// validation + dialect-aware quoting (B1 + A1 fix). The previous
/// implementation used inline `format!("SAVEPOINT {}", name)` which bypassed
/// the safety net and reintroduced SQL injection via the FFI surface.
///
/// Resolves `txn_id` under the transactions lock, then runs the ODBC savepoint
/// SQL without holding that lock (ISSUE-TXN-SAVEPOINT-LOCK). Active
/// transactions are stored as `Arc<Transaction>` so the handle can be cloned
/// for the duration of the driver round-trip.
pub(crate) fn savepoint_dispatch<F>(
    txn_id: c_uint,
    name: *const c_char,
    op: &str,
    action: F,
) -> c_int
where
    F: Fn(&Transaction, &str) -> Result<()>,
{
    if name.is_null() {
        return 1;
    }
    // SAFETY: `name` is non-null (checked above); caller guarantees it is a
    // valid NUL-terminated C string that remains valid for the duration of
    // this FFI call.
    let name_str = match unsafe { CStr::from_ptr(name).to_str() } {
        Ok(s) => s,
        Err(_) => return 1,
    };
    let Some(txn) = state::get_transaction(txn_id) else {
        if let Some(mut gs) = try_lock_global_state() {
            set_error(&mut gs, format!("Invalid transaction ID: {}", txn_id));
        }
        return 1;
    };
    let conn_id = txn.conn_id();

    match action(txn.as_ref(), name_str) {
        Ok(()) => 0,
        Err(e) => {
            if let Some(mut gs) = try_lock_global_state() {
                set_connection_error(&mut gs, conn_id, format!("Savepoint {op} failed: {}", e));
            }
            1
        }
    }
}

/// Create a savepoint within an active transaction.
/// txn_id: transaction ID from odbc_transaction_begin
/// name: savepoint name (UTF-8, null-terminated). Must match the identifier
///       grammar enforced by `engine::identifier::validate_identifier`
///       (ASCII letter or `_`, then letters/digits/`_`, ≤128 chars). Names
///       containing semicolons, quotes or whitespace are rejected.
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_savepoint_create(txn_id: c_uint, name: *const c_char) -> c_int {
    crate::ffi_guard_int!({
        savepoint_dispatch(txn_id, name, "create", |txn, n| txn.savepoint_create(n))
    })
}

/// Rollback to a savepoint. Transaction remains active.
/// txn_id: transaction ID from odbc_transaction_begin
/// name: savepoint name (UTF-8, null-terminated; same grammar as
///       `odbc_savepoint_create`).
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_savepoint_rollback(txn_id: c_uint, name: *const c_char) -> c_int {
    crate::ffi_guard_int!({
        savepoint_dispatch(txn_id, name, "rollback", |txn, n| {
            txn.savepoint_rollback_to(n)
        })
    })
}

/// Release a savepoint. Transaction remains active.
/// On SQL Server this is a successful no-op (the dialect has no RELEASE).
/// txn_id: transaction ID from odbc_transaction_begin
/// name: savepoint name (UTF-8, null-terminated; same grammar as
///       `odbc_savepoint_create`).
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_savepoint_release(txn_id: c_uint, name: *const c_char) -> c_int {
    crate::ffi_guard_int!({
        savepoint_dispatch(txn_id, name, "release", |txn, n| txn.savepoint_release(n))
    })
}

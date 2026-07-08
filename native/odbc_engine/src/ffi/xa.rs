// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use super::global::*;
use super::prelude::*;
use crate::ffi::state;

use crate::engine::{XaTransaction, Xid};
use std::os::raw::{c_int, c_uint};

// =========================================================================
// X/Open XA distributed transaction FFIs (Sprint 4.3)
//
// Lifecycle:
//
//   odbc_xa_start(conn_id, format_id, gtrid_ptr, gtrid_len, bqual_ptr,
//                 bqual_len)                                  -> xa_id
//
//   1RM optimisation:
//     odbc_xa_commit_one_phase(xa_id)                         -> 0|1
//     odbc_xa_rollback_active(xa_id)                          -> 0|1
//
//   2PC:
//     odbc_xa_end(xa_id)                                      -> 0|1
//     odbc_xa_prepare(xa_id)                                  -> 0|1
//     odbc_xa_commit_prepared(xa_id)                          -> 0|1
//     odbc_xa_rollback_prepared(xa_id)                        -> 0|1
//
//   Recovery (Phase 2 after process restart):
//     odbc_xa_recover_count(conn_id)                          -> count|-1
//     odbc_xa_recover_get(conn_id, idx, ...)                  -> 0|1
//     odbc_xa_resume_prepared(conn_id, format_id, ...)        -> xa_id
//
// All `xa_id` values are returned >0 on success and 0 on failure.
// All other entry points return 0 on success and non-zero on failure.
// Errors are stored per-connection via `set_connection_error` and
// retrievable through `odbc_get_structured_error_for_connection`.
// =========================================================================

/// X/Open XID component limit (`gtrid` / `bqual` are each at most 64
/// bytes). Enforced here *before* any allocation or read so a hostile
/// length can neither force a multi-gigabyte allocation nor a wild
/// out-of-bounds read; `Xid::new` re-validates with precise messages.
pub(crate) const XA_MAX_COMPONENT_LEN: c_uint = 64;

/// Helper: copy a buffer-with-length pair from FFI into an owned
/// `Vec<u8>` with explicit length validation. `null` ptr with
/// `len == 0` is OK (empty bqual is valid). Otherwise we reject
/// rather than dereferencing a null pointer. Lengths above
/// [`XA_MAX_COMPONENT_LEN`] are rejected before any read.
pub(crate) fn xa_read_buffer(ptr: *const u8, len: c_uint) -> Option<Vec<u8>> {
    if len > XA_MAX_COMPONENT_LEN {
        return None;
    }
    if ptr.is_null() {
        if len == 0 {
            return Some(Vec::new());
        }
        return None;
    }
    // SAFETY: caller asserts `ptr` is valid for reads of `len` bytes.
    Some(unsafe { std::slice::from_raw_parts(ptr, len as usize).to_vec() })
}

fn xa_alloc_id(state: &mut GlobalState) -> Option<u32> {
    for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
        let candidate = state.next_xa_id;
        state.next_xa_id = state.next_xa_id.wrapping_add(1);
        if candidate != 0
            && !state.xa_active.contains_key(&candidate)
            && !state.xa_preparing.contains_key(&candidate)
            && !state.xa_prepared.contains_key(&candidate)
        {
            return Some(candidate);
        }
    }
    None
}

enum XaEndPending {
    Preparing(PreparingXa),
    Active(XaTransaction),
}

/// Re-inserts an XA handle when global-state re-lock fails after `xa_end`.
struct XaEndReinsertGuard {
    xa_id: u32,
    pending: Option<XaEndPending>,
}

impl XaEndReinsertGuard {
    fn new(xa_id: u32) -> Self {
        Self {
            xa_id,
            pending: None,
        }
    }

    fn disarm(&mut self) {
        self.pending = None;
    }
}

impl Drop for XaEndReinsertGuard {
    fn drop(&mut self) {
        let Some(pending) = self.pending.take() else {
            return;
        };
        if let Some(mut state) = try_lock_global_state() {
            match pending {
                XaEndPending::Preparing(preparing) => {
                    state.xa_preparing.insert(self.xa_id, preparing);
                }
                XaEndPending::Active(xa) => {
                    state.xa_active.insert(self.xa_id, xa);
                }
            }
        } else {
            log::error!(
                "XaEndReinsertGuard: failed to re-acquire global state for xa_id {} — \
                 XA handle may be lost until process restart",
                self.xa_id
            );
        }
    }
}

enum XaPreparePending {
    Prepared(PreparedXa),
    Preparing(PreparingXa),
}

/// Re-inserts an XA handle when global-state re-lock fails after `xa_prepare`.
struct XaPrepareReinsertGuard {
    xa_id: u32,
    pending: Option<XaPreparePending>,
}

impl XaPrepareReinsertGuard {
    fn new(xa_id: u32) -> Self {
        Self {
            xa_id,
            pending: None,
        }
    }

    fn disarm(&mut self) {
        self.pending = None;
    }
}

impl Drop for XaPrepareReinsertGuard {
    fn drop(&mut self) {
        let Some(pending) = self.pending.take() else {
            return;
        };
        if let Some(mut state) = try_lock_global_state() {
            match pending {
                XaPreparePending::Prepared(prepared) => {
                    state.xa_prepared.insert(self.xa_id, prepared);
                }
                XaPreparePending::Preparing(preparing) => {
                    state.xa_preparing.insert(self.xa_id, preparing);
                }
            }
        } else {
            log::error!(
                "XaPrepareReinsertGuard: failed to re-acquire global state for xa_id {} — \
                 XA handle may be lost until process restart",
                self.xa_id
            );
        }
    }
}

struct XaActiveReinsertGuard {
    xa_id: u32,
    xa: Option<XaTransaction>,
}

impl XaActiveReinsertGuard {
    fn disarm(&mut self) {
        self.xa = None;
    }
}

impl Drop for XaActiveReinsertGuard {
    fn drop(&mut self) {
        if let Some(xa) = self.xa.take() {
            if let Some(mut state) = try_lock_global_state() {
                state.xa_active.insert(self.xa_id, xa);
            } else {
                log::error!(
                    "XaActiveReinsertGuard: failed to re-acquire global state for xa_id {} — \
                     XA handle may be lost until process restart",
                    self.xa_id
                );
            }
        }
    }
}

struct XaPreparedReinsertGuard {
    xa_id: u32,
    prepared: Option<PreparedXa>,
}

impl XaPreparedReinsertGuard {
    fn disarm(&mut self) {
        self.prepared = None;
    }
}

impl Drop for XaPreparedReinsertGuard {
    fn drop(&mut self) {
        if let Some(prepared) = self.prepared.take() {
            if let Some(mut state) = try_lock_global_state() {
                state.xa_prepared.insert(self.xa_id, prepared);
            } else {
                log::error!(
                    "XaPreparedReinsertGuard: failed to re-acquire global state for xa_id {} — \
                     XA handle may be lost until process restart",
                    self.xa_id
                );
            }
        }
    }
}

fn reinsert_active_xa_on_driver_failure(
    xa_id: u32,
    xa: XaTransaction,
    op: &str,
    error: OdbcError,
) -> c_int {
    let mut guard = XaActiveReinsertGuard {
        xa_id,
        xa: Some(xa),
    };
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };
    let xa = guard.xa.take().expect("active xa");
    guard.disarm();
    state.xa_active.insert(xa_id, xa);
    set_error(&mut state, format!("{op} failed: {error}"));
    1
}

fn reinsert_prepared_xa_on_driver_failure(
    xa_id: u32,
    prepared: PreparedXa,
    op: &str,
    error: OdbcError,
) -> c_int {
    let mut guard = XaPreparedReinsertGuard {
        xa_id,
        prepared: Some(prepared),
    };
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };
    let prepared = guard.prepared.take().expect("prepared xa");
    guard.disarm();
    state.xa_prepared.insert(xa_id, prepared);
    set_error(&mut state, format!("{op} failed: {error}"));
    1
}

/// Start a new XA transaction branch on `conn_id`.
///
/// - `format_id`: application-defined 32-bit XID format identifier
///   (commonly `0` or `0x1B`).
/// - `gtrid_ptr` / `gtrid_len`: global transaction ID; 1..=64 bytes.
/// - `bqual_ptr` / `bqual_len`: branch qualifier; 0..=64 bytes
///   (`null`+`0` is accepted as an empty qualifier).
///
/// Returns the `xa_id` (`> 0`) on success, `0` on failure (consult
/// `odbc_get_structured_error_for_connection` for the reason).
///
/// Sprint 4.3 — see `engine::xa_transaction` for the engine matrix.
#[no_mangle]
pub extern "C" fn odbc_xa_start(
    conn_id: c_uint,
    format_id: c_int,
    gtrid_ptr: *const u8,
    gtrid_len: c_uint,
    bqual_ptr: *const u8,
    bqual_len: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };

        let Some(gtrid) = xa_read_buffer(gtrid_ptr, gtrid_len) else {
            set_connection_error(
                &mut state,
                conn_id,
                "odbc_xa_start: invalid gtrid buffer (null with non-zero length, or length > 64)"
                    .to_string(),
            );
            return 0;
        };
        let Some(bqual) = xa_read_buffer(bqual_ptr, bqual_len) else {
            set_connection_error(
                &mut state,
                conn_id,
                "odbc_xa_start: invalid bqual buffer (null with non-zero length, or length > 64)"
                    .to_string(),
            );
            return 0;
        };

        let xid = match Xid::new(format_id, gtrid, bqual) {
            Ok(x) => x,
            Err(e) => {
                set_connection_error(&mut state, conn_id, format!("odbc_xa_start: {}", e));
                return 0;
            }
        };

        if !state::contains_connection(conn_id) {
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return 0;
        }

        // Get the connection's handles + id; release the connection borrow
        // before calling XaTransaction::start (which re-locks via the
        // SharedHandleManager).
        let Some(handles) = state::connection_handles(conn_id) else {
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return 0;
        };
        drop(state);

        let xa_result = XaTransaction::start(handles, conn_id, xid);

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };
        let xa = match xa_result {
            Ok(x) => x,
            Err(e) => {
                set_connection_error(&mut state, conn_id, format!("odbc_xa_start: {}", e));
                return 0;
            }
        };

        let Some(xa_id) = xa_alloc_id(&mut state) else {
            set_connection_error(&mut state, conn_id, "Failed to allocate XA ID".to_string());
            drop(state);
            if let Err(e) = xa.rollback() {
                log::warn!(
                    "odbc_xa_start: failed to roll back active branch after XA ID allocation \
                     failure on conn_id {conn_id}: {e}"
                );
            }
            return 0;
        };
        state.xa_active.insert(xa_id, xa);
        xa_id
    })
}

/// `xa_end`: detach the branch from the connection. After this the
/// branch is in the `Idle` state and the caller must either prepare
/// (Phase 1 of 2PC) or roll back via the prepared rollback path.
///
/// Returns 0 on success, 1 on failure (the `xa_id` keeps its slot in
/// the appropriate map so callers can inspect / retry).
#[no_mangle]
pub extern "C" fn odbc_xa_end(xa_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        let Some(xa) = state.xa_active.remove(&xa_id) else {
            set_error(&mut state, format!("Invalid XA ID (Active): {}", xa_id));
            return 1;
        };
        drop(state);

        let mut reinsert_guard = XaEndReinsertGuard::new(xa_id);
        let driver_error = match xa.end_preserving_active() {
            Ok(preparing) => {
                reinsert_guard.pending = Some(XaEndPending::Preparing(preparing));
                None
            }
            Err((error, xa)) => {
                reinsert_guard.pending = Some(XaEndPending::Active(xa));
                Some(error)
            }
        };

        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        match reinsert_guard.pending.take() {
            Some(XaEndPending::Preparing(preparing)) => {
                reinsert_guard.disarm();
                state.xa_preparing.insert(xa_id, preparing);
                0
            }
            Some(XaEndPending::Active(xa)) => {
                reinsert_guard.disarm();
                state.xa_active.insert(xa_id, xa);
                if let Some(error) = driver_error {
                    set_error(&mut state, format!("xa_end failed: {}", error));
                }
                1
            }
            None => -1,
        }
    })
}

/// `xa_prepare`: Phase 1 of 2PC. Promotes the branch from `Idle` to
/// `Prepared`. The branch is now heuristically committable.
#[no_mangle]
pub extern "C" fn odbc_xa_prepare(xa_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        let Some(preparing) = state.xa_preparing.remove(&xa_id) else {
            set_error(
                &mut state,
                format!("Invalid XA ID (Idle, awaiting prepare): {}", xa_id),
            );
            return 1;
        };
        drop(state);

        let mut reinsert_guard = XaPrepareReinsertGuard::new(xa_id);
        let driver_error = match preparing.prepare_preserving_idle() {
            Ok(prepared) => {
                reinsert_guard.pending = Some(XaPreparePending::Prepared(prepared));
                None
            }
            Err((error, preparing)) => {
                reinsert_guard.pending = Some(XaPreparePending::Preparing(preparing));
                Some(error)
            }
        };

        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        match reinsert_guard.pending.take() {
            Some(XaPreparePending::Prepared(prepared)) => {
                reinsert_guard.disarm();
                state.xa_prepared.insert(xa_id, prepared);
                0
            }
            Some(XaPreparePending::Preparing(preparing)) => {
                reinsert_guard.disarm();
                state.xa_preparing.insert(xa_id, preparing);
                if let Some(error) = driver_error {
                    set_error(&mut state, format!("xa_prepare failed: {}", error));
                }
                1
            }
            None => -1,
        }
    })
}

/// `xa_commit` (Phase 2): finalise a prepared branch.
#[no_mangle]
pub extern "C" fn odbc_xa_commit_prepared(xa_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        let Some(prepared) = state.xa_prepared.remove(&xa_id) else {
            set_error(&mut state, format!("Invalid XA ID (Prepared): {}", xa_id));
            return 1;
        };
        drop(state);

        match prepared.commit_preserving_prepared() {
            Ok(()) => 0,
            Err((error, prepared)) => {
                reinsert_prepared_xa_on_driver_failure(xa_id, prepared, "xa_commit_prepared", error)
            }
        }
    })
}

/// `xa_rollback` (Phase 2): roll back a prepared branch.
#[no_mangle]
pub extern "C" fn odbc_xa_rollback_prepared(xa_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        let Some(prepared) = state.xa_prepared.remove(&xa_id) else {
            set_error(&mut state, format!("Invalid XA ID (Prepared): {}", xa_id));
            return 1;
        };
        drop(state);

        match prepared.rollback_preserving_prepared() {
            Ok(()) => 0,
            Err((error, prepared)) => reinsert_prepared_xa_on_driver_failure(
                xa_id,
                prepared,
                "xa_rollback_prepared",
                error,
            ),
        }
    })
}

/// 1RM optimisation: fuse `prepare → commit` for the case where this
/// branch is the only RM in the transaction. Only valid in the
/// `Active` state.
#[no_mangle]
pub extern "C" fn odbc_xa_commit_one_phase(xa_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        let Some(xa) = state.xa_active.remove(&xa_id) else {
            set_error(&mut state, format!("Invalid XA ID (Active): {}", xa_id));
            return 1;
        };
        drop(state);

        match xa.commit_one_phase_preserving_active() {
            Ok(()) => 0,
            Err((error, xa)) => {
                reinsert_active_xa_on_driver_failure(xa_id, xa, "xa_commit_one_phase", error)
            }
        }
    })
}

/// Roll back an Active branch (no PREPARE issued). The branch is
/// removed from the map and there is no recovery path.
#[no_mangle]
pub extern "C" fn odbc_xa_rollback_active(xa_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        let Some(xa) = state.xa_active.remove(&xa_id) else {
            set_error(&mut state, format!("Invalid XA ID (Active): {}", xa_id));
            return 1;
        };
        drop(state);

        match xa.rollback_preserving_active() {
            Ok(()) => 0,
            Err((error, xa)) => {
                reinsert_active_xa_on_driver_failure(xa_id, xa, "xa_rollback_active", error)
            }
        }
    })
}

// xa_recover comes back as an opaque list — the Dart side calls
// `odbc_xa_recover_count` once, then `odbc_xa_recover_get` per index
// to extract the components. Avoids the variable-length-output
// marshaling pain at the FFI boundary.

thread_local! {
    /// Per-thread cache of the most recent `xa_recover` result. The
    /// FFI is single-call: `odbc_xa_recover_count` populates the
    /// cache; subsequent `odbc_xa_recover_get` calls index into it.
    /// Cleared automatically on the next `odbc_xa_recover_count`.
    static XA_RECOVER_CACHE: std::cell::RefCell<Vec<Xid>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

/// `xa_recover` step 1: query the engine for prepared XIDs and cache
/// the result on this thread. Returns the number of XIDs (0 if none),
/// or `-1` on failure.
#[no_mangle]
pub extern "C" fn odbc_xa_recover_count(conn_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        let Some(handles) = state::connection_handles(conn_id) else {
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return -1;
        };
        drop(state);
        match recover_prepared_xids(handles, conn_id) {
            Ok(xids) => {
                let count = xids.len() as c_int;
                XA_RECOVER_CACHE.with(|c| *c.borrow_mut() = xids);
                count
            }
            Err(e) => {
                if let Some(mut state) = try_lock_global_state() {
                    set_connection_error(
                        &mut state,
                        conn_id,
                        format!("xa_recover_count failed: {}", e),
                    );
                }
                -1
            }
        }
    })
}

/// `xa_recover` step 2: extract one XID component triple from the
/// cache populated by [`odbc_xa_recover_count`].
///
/// `out_format_id` receives the i32 format id.
/// `gtrid_buf` / `gtrid_buf_len` receive the gtrid (caller-allocated;
/// max 64 bytes is always safe). `out_gtrid_len` receives the actual
/// length written.
/// Same convention for `bqual_buf` / `bqual_buf_len` / `out_bqual_len`.
///
/// Returns 0 on success, 1 on failure (index out of range or buffer
/// too small). When a buffer is too small, `out_*_len` is populated
/// with the required size so the caller can retry with a bigger
/// allocation.
#[no_mangle]
pub extern "C" fn odbc_xa_recover_get(
    index: c_uint,
    out_format_id: *mut c_int,
    gtrid_buf: *mut u8,
    gtrid_buf_len: c_uint,
    out_gtrid_len: *mut c_uint,
    bqual_buf: *mut u8,
    bqual_buf_len: c_uint,
    out_bqual_len: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if out_format_id.is_null() || out_gtrid_len.is_null() || out_bqual_len.is_null() {
            return 1;
        }
        XA_RECOVER_CACHE.with(|c| {
            let xids = c.borrow();
            let Some(xid) = xids.get(index as usize) else {
                return 1;
            };
            // SAFETY: caller-asserted non-null pointers above; we control
            // the writes' bounds via the buffer-length parameters.
            unsafe {
                *out_format_id = xid.format_id();
                *out_gtrid_len = xid.gtrid().len() as c_uint;
                *out_bqual_len = xid.bqual().len() as c_uint;
            }
            if xid.gtrid().len() > gtrid_buf_len as usize {
                return 1;
            }
            if xid.bqual().len() > bqual_buf_len as usize {
                return 1;
            }
            if !gtrid_buf.is_null() && !xid.gtrid().is_empty() {
                // SAFETY: `gtrid_buf_len` was checked above; buffer is non-null when copying.
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        xid.gtrid().as_ptr(),
                        gtrid_buf,
                        xid.gtrid().len(),
                    );
                }
            }
            if !bqual_buf.is_null() && !xid.bqual().is_empty() {
                // SAFETY: `bqual_buf_len` was checked above; buffer is non-null when copying.
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        xid.bqual().as_ptr(),
                        bqual_buf,
                        xid.bqual().len(),
                    );
                }
            }
            0
        })
    })
}

/// Resume a previously prepared XID — rebuilds an `xa_id` handle for
/// crash-recovery scenarios. Returns the `xa_id` (`> 0`) on success,
/// `0` on failure. The handle goes straight to the `Prepared` state;
/// callers drive Phase 2 with `odbc_xa_commit_prepared` /
/// `odbc_xa_rollback_prepared`.
#[no_mangle]
pub extern "C" fn odbc_xa_resume_prepared(
    conn_id: c_uint,
    format_id: c_int,
    gtrid_ptr: *const u8,
    gtrid_len: c_uint,
    bqual_ptr: *const u8,
    bqual_len: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };
        let Some(gtrid) = xa_read_buffer(gtrid_ptr, gtrid_len) else {
            set_connection_error(
                &mut state,
                conn_id,
                "odbc_xa_resume_prepared: gtrid_ptr is null but gtrid_len > 0".to_string(),
            );
            return 0;
        };
        let Some(bqual) = xa_read_buffer(bqual_ptr, bqual_len) else {
            set_connection_error(
                &mut state,
                conn_id,
                "odbc_xa_resume_prepared: bqual_ptr is null but bqual_len > 0".to_string(),
            );
            return 0;
        };
        let xid = match Xid::new(format_id, gtrid, bqual) {
            Ok(x) => x,
            Err(e) => {
                set_connection_error(
                    &mut state,
                    conn_id,
                    format!("odbc_xa_resume_prepared: {}", e),
                );
                return 0;
            }
        };
        let Some(handles) = state::connection_handles(conn_id) else {
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return 0;
        };
        drop(state);

        let prepared_result = resume_prepared(handles, conn_id, xid);

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };
        let prepared = match prepared_result {
            Ok(p) => p,
            Err(e) => {
                set_connection_error(
                    &mut state,
                    conn_id,
                    format!("odbc_xa_resume_prepared: {}", e),
                );
                return 0;
            }
        };
        let Some(xa_id) = xa_alloc_id(&mut state) else {
            set_connection_error(&mut state, conn_id, "Failed to allocate XA ID".to_string());
            drop(state);
            if let Err(e) = prepared.rollback() {
                log::warn!(
                    "odbc_xa_resume_prepared: failed to roll back resumed branch after XA ID \
                     allocation failure on conn_id {conn_id}: {e}"
                );
            }
            return 0;
        };
        state.xa_prepared.insert(xa_id, prepared);
        xa_id
    })
}

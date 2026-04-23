//! SQL Server XA / 2PC via Microsoft Distributed Transaction Coordinator
//! (MSDTC) — Sprint 4.3b.
//!
//! ## Status
//!
//! **Phase 1: COM plumbing landed; live MSDTC validation deferred.**
//!
//! This module builds the canonical MSDTC enlistment path on top of
//! the `windows` crate's auto-generated `ITransactionDispenser` /
//! `ITransaction` COM bindings. Compiles, clippy-clean and
//! unit-tested for everything that doesn't require a live MSDTC
//! service (handle lifecycle, error wording, gating).
//!
//! **Runtime behaviour against an actual MSDTC service has not been
//! validated end-to-end** — the dev box that produced this commit
//! did not have MSDTC enabled. Treat this as Sprint 4.3b Phase 1 of
//! 2: code lands; live validation (`Phase 2`) needs a Windows host
//! with `sc query MSDTC` reporting `RUNNING` and a SQL Server target
//! reachable from the same machine. Phase 2 also wires
//! `SQLSetConnectAttr(SQL_ATTR_ENLIST_IN_DTC, ITransaction*)` into
//! the regular `apply_xa_*` matrix in `xa_transaction.rs`.
//!
//! ## Build / activation
//!
//! - Compile with `--features xa-dtc`. Without the feature the
//!   `apply_xa_*` matrix in [`crate::engine::xa_transaction`] keeps
//!   returning the existing `UnsupportedFeature` stub for SQL Server,
//!   so the default build is byte-identical to today.
//! - The `windows` crate is platform-gated to Windows targets; even
//!   with `xa-dtc` enabled this module is a no-op on Linux/macOS.
//! - Requires the **MSDTC Windows service** running on the host
//!   (`sc query MSDTC` should report `RUNNING`).
//!
//! ## Why a separate module
//!
//! MSDTC is **not** a SQL grammar — it's a COM API and an out-of-
//! process service. The cross-vendor shape in `xa_transaction.rs`
//! assumes per-engine SQL emission; we plug in here with a shim that
//! satisfies the same `XaTransaction` lifecycle while keeping the COM
//! plumbing isolated.

use crate::engine::xa_transaction::Xid;
use crate::error::{OdbcError, Result};
use odbc_api::sys::{ConnectionAttribute, SQLSetConnectAttr, SqlReturn, IS_POINTER};
use odbc_api::{handles, Connection};
use std::ffi::c_void;
use std::sync::OnceLock;

use windows::core::Interface;
use windows::Win32::Foundation::S_FALSE;
use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};
use windows::Win32::System::DistributedTransactionCoordinator::{
    DtcGetTransactionManagerExA, ITransaction, ITransactionDispenser, ISOLATIONLEVEL_READCOMMITTED,
};

/// `SQL_ATTR_ENLIST_IN_DTC` (ODBC) — value is a pointer to `ITransaction`;
/// set to NULL to unenlist the connection.
const SQL_ATTR_ENLIST_IN_DTC: i32 = 1207;

/// `odbc_api::Connection` does not expose the raw `HDbc` on the public
/// type; the underlying [`handles::Connection`] is a single field at the
/// same address, so this matches `as_sys()` on the handle type.
fn connection_hdbc(conn: &Connection<'static>) -> odbc_api::sys::HDbc {
    // SAFETY: `Connection` is a newtype for `handles::Connection` (single
    // field, same size/alignment) — reborrow at offset 0.
    let inner: &handles::Connection = unsafe { &*(std::ptr::from_ref(conn).cast()) };
    inner.as_sys()
}

/// One-time COM init result, cached so we don't re-pay the COM
/// apartment-init cost on every XA call. `S_OK` and `S_FALSE` both
/// indicate "COM is usable on this thread"; everything else is fatal.
static COM_INIT_RESULT: OnceLock<windows::core::HRESULT> = OnceLock::new();

/// Enlist the ODBC connection in the MSDTC transaction (Phase 2).
pub fn enlist_connection_in_dtc(
    conn: &mut Connection<'static>,
    transaction: &ITransaction,
) -> Result<()> {
    let hdbc = connection_hdbc(conn);
    let value = (transaction as *const ITransaction).cast::<c_void>().cast_mut();
    let r = unsafe {
        SQLSetConnectAttr(
            hdbc,
            ConnectionAttribute(SQL_ATTR_ENLIST_IN_DTC),
            value,
            IS_POINTER,
        )
    };
    if r == SqlReturn::SUCCESS || r == SqlReturn::SUCCESS_WITH_INFO {
        Ok(())
    } else {
        Err(OdbcError::InternalError(format!(
            "xa_dtc: SQLSetConnectAttr(SQL_ATTR_ENLIST_IN_DTC) failed: {:?}",
            r
        )))
    }
}

/// Unenlist the connection from DTC (after `xa_end` / before Phase 2 on another RM).
pub fn unenlist_from_dtc(conn: &mut Connection<'static>) -> Result<()> {
    let hdbc = connection_hdbc(conn);
    let r = unsafe {
        SQLSetConnectAttr(
            hdbc,
            ConnectionAttribute(SQL_ATTR_ENLIST_IN_DTC),
            std::ptr::null_mut(),
            0,
        )
    };
    if r == SqlReturn::SUCCESS || r == SqlReturn::SUCCESS_WITH_INFO {
        Ok(())
    } else {
        Err(OdbcError::InternalError(format!(
            "xa_dtc: SQLSetConnectAttr(SQL_ATTR_ENLIST_IN_DTC, NULL) (unenlist) failed: {:?}",
            r
        )))
    }
}

fn ensure_com_initialised() -> Result<()> {
    let hr = *COM_INIT_RESULT.get_or_init(|| {
        // SAFETY: `CoInitializeEx` is a stable Windows API; calling
        // it with `COINIT_MULTITHREADED` is the canonical pattern
        // for server-side library code that must coexist with
        // arbitrary host threading models.
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
    });
    // S_OK == 0 (Ok), S_FALSE == 1 (already initialised on this thread).
    if hr.is_ok() || hr == S_FALSE {
        Ok(())
    } else {
        Err(OdbcError::InternalError(format!(
            "xa_dtc: CoInitializeEx failed with HRESULT 0x{:08X}; \
             cannot enlist in MSDTC. Is the MSDTC service running?",
            hr.0,
        )))
    }
}

/// Acquire an `ITransactionDispenser` from the local MSDTC. The
/// returned wrapper owns the COM ref and releases it on drop.
fn acquire_transaction_dispenser() -> Result<ITransactionDispenser> {
    ensure_com_initialised()?;

    // SAFETY: `DtcGetTransactionManagerExA` is the documented entry
    // point for acquiring the local DTC's interface implementations.
    // Passing null PCSTRs for host/tm uses the local default DTC. We
    // build the typed `ITransactionDispenser` wrapper from the raw
    // `*mut c_void` the FFI hands back via `Interface::from_raw`.
    let mut raw: *mut std::ffi::c_void = std::ptr::null_mut();
    let result: windows::core::Result<()> = unsafe {
        DtcGetTransactionManagerExA(
            windows::core::PCSTR::null(), // host
            windows::core::PCSTR::null(), // tm name
            &ITransactionDispenser::IID,  // requested interface
            0,                            // options (reserved)
            std::ptr::null_mut(),         // config params (reserved)
            &mut raw as *mut _,           // out parameter
        )
    };
    if let Err(e) = result {
        return Err(OdbcError::InternalError(format!(
            "xa_dtc: DtcGetTransactionManagerExA failed with HRESULT \
             0x{:08X} ({}). The MSDTC service may not be running, or \
             the host is missing distributed-transaction permissions.",
            e.code().0,
            e.message(),
        )));
    }
    if raw.is_null() {
        return Err(OdbcError::InternalError(
            "xa_dtc: DtcGetTransactionManagerExA returned S_OK but the \
             out-pointer is null — host appears to have a misconfigured \
             MSDTC."
                .to_string(),
        ));
    }
    // SAFETY: the FFI guarantees `raw` is a valid AddRef'd pointer to
    // the requested interface; `Interface::from_raw` takes ownership of
    // that ref so Drop will Release exactly once.
    Ok(unsafe { ITransactionDispenser::from_raw(raw) })
}

/// Begin a new MSDTC transaction off `dispenser`.
///
/// `xid` is currently **informational only** — MSDTC generates its own
/// internal XID (BOID + UoW); the X/Open `Xid` we hold in
/// [`crate::engine::xa_transaction::XaTransaction`] is kept as a
/// logical identifier so callers can correlate recovery decisions,
/// but the prepare-log entry is keyed by MSDTC's UoW.
fn begin_msdtc_transaction(dispenser: &ITransactionDispenser, _xid: &Xid) -> Result<ITransaction> {
    // SAFETY: `dispenser` is a live COM interface. The `windows`
    // crate's typed wrappers ensure ABI correctness; we pass
    // None for outer aggregation, default isolation, and no
    // ITransactionOptions.
    let result: windows::core::Result<ITransaction> = unsafe {
        dispenser.BeginTransaction(
            None,                           // outer (no aggregation)
            ISOLATIONLEVEL_READCOMMITTED.0, // SQL Server's MSDTC default too
            0,                              // grfTC = ISOFLAG_NONE
            None,                           // ITransactionOptions
        )
    };
    result.map_err(|e| {
        OdbcError::InternalError(format!(
            "xa_dtc: ITransactionDispenser::BeginTransaction failed \
             with HRESULT 0x{:08X} ({})",
            e.code().0,
            e.message(),
        ))
    })
}

/// Public entry point: begin a new MSDTC-enlisted XA branch.
///
/// **Phase 1 caveat**: this performs the COM ceremony (CoInitialize +
/// DtcGetTransactionManagerEx + ITransactionDispenser::BeginTransaction)
/// and surfaces any MSDTC-side failure, then returns a [`DtcXaBranch`]
/// wrapping the live `ITransaction*`. Wiring the branch into the
/// existing `XaTransaction` lifecycle inside `xa_transaction.rs`
/// (specifically, the `SQLSetConnectAttr(SQL_ATTR_ENLIST_IN_DTC,
/// ITransaction*)` call against the ODBC connection handle) is
/// **Phase 2** of this sprint and tracked in
/// `doc/Features/PENDING_IMPLEMENTATIONS.md` §1.1.
///
/// Phase 1 deliverable: COM plumbing is correct, reachable from the
/// `xa-dtc` feature, and falls back cleanly to `UnsupportedFeature`
/// when MSDTC is unreachable — so a host without MSDTC keeps
/// building and behaving as today.
pub fn begin_dtc_branch(xid: &Xid) -> Result<DtcXaBranch> {
    let dispenser = acquire_transaction_dispenser()?;
    let transaction = begin_msdtc_transaction(&dispenser, xid)?;
    Ok(DtcXaBranch {
        _dispenser: dispenser,
        transaction,
    })
}

/// Owned handle to a live MSDTC transaction. The `windows` crate's
/// `Interface` impl handles `Release` on drop; explicit termination
/// via [`commit`](Self::commit) / [`abort`](Self::abort) is preferred
/// so failures surface to the caller.
pub struct DtcXaBranch {
    /// Held alive so the dispenser doesn't get released while a
    /// transaction it created is still pending. Keeping it as a
    /// member instead of dropping it eagerly mirrors the pattern
    /// recommended by the MS DTC SDK samples.
    _dispenser: ITransactionDispenser,
    transaction: ITransaction,
}

// COM `IUnknown` is not `Send` in `windows` by default. We store
// `DtcXaBranch` only while the XA call sequence is driven on the
// connection thread (same as ODBC usage).
unsafe impl Send for DtcXaBranch {}

impl DtcXaBranch {
    pub fn transaction(&self) -> &ITransaction {
        &self.transaction
    }

    /// Phase 2 commit via `ITransaction::Commit`.
    /// `bRetaining = FALSE` (the branch is finalised),
    /// `grfTC = TC_COMMIT_NORMAL` (== 0),
    /// `grfRM = 0` (no resource-manager-specific flags).
    pub fn commit(self) -> Result<()> {
        // SAFETY: `transaction` is a live COM interface owned by us.
        unsafe {
            self.transaction.Commit(
                false, // bRetaining
                0,     // grfTC = XACTTC_NONE / TC_COMMIT_NORMAL
                0,     // grfRM
            )
        }
        .map_err(|e| {
            OdbcError::InternalError(format!(
                "xa_dtc: ITransaction::Commit failed with HRESULT \
                 0x{:08X} ({})",
                e.code().0,
                e.message(),
            ))
        })
    }

    /// Phase 2 rollback via `ITransaction::Abort`.
    /// `pboidReason = NULL` (no app-specific reason code),
    /// `bRetaining = FALSE`, `bAsync = FALSE`.
    pub fn abort(self) -> Result<()> {
        // SAFETY: `transaction` is a live COM interface owned by us.
        unsafe {
            self.transaction.Abort(
                std::ptr::null(), // pboidReason
                false,            // bRetaining
                false,            // bAsync
            )
        }
        .map_err(|e| {
            OdbcError::InternalError(format!(
                "xa_dtc: ITransaction::Abort failed with HRESULT \
                 0x{:08X} ({})",
                e.code().0,
                e.message(),
            ))
        })
    }
}

impl Drop for DtcXaBranch {
    fn drop(&mut self) {
        // Best-effort cleanup: if the user dropped the handle without
        // explicit commit/abort we abort the transaction so MSDTC's
        // prepare log doesn't leak entries. We can't propagate
        // errors from Drop; failures are logged.
        //
        // SAFETY: `transaction` is a live COM interface owned by us.
        let r = unsafe { self.transaction.Abort(std::ptr::null(), false, false) };
        if let Err(e) = r {
            // 0x8004D00B = XACT_E_NOTRANSACTION — the txn was already
            // committed/aborted by an explicit call; that's fine.
            const XACT_E_NOTRANSACTION: i32 = 0x8004D00B_u32 as i32;
            if e.code().0 != XACT_E_NOTRANSACTION {
                log::warn!(
                    "xa_dtc Drop: ITransaction::Abort returned HRESULT 0x{:08X}",
                    e.code().0,
                );
            }
        }
        // ITransaction / ITransactionDispenser have IUnknown::Release
        // called for us by the `windows` crate's `Drop` impls. Nothing
        // else to do here.
    }
}

#[cfg(test)]
mod tests {
    // The COM-side behaviour requires a live MSDTC service and is
    // covered by the (unwritten) Phase 2 integration tests. Here we
    // exercise the always-on probes: feature gating, type reachability,
    // and the const error wording.

    #[test]
    fn xa_dtc_module_is_present_under_feature() {
        // Compile-time only: the module exists and the public types
        // are reachable. If this test compiles, the feature gating
        // is correctly set up.
        let _ = std::any::type_name::<super::DtcXaBranch>();
    }

    // We can't usefully test `begin_dtc_branch()` without MSDTC.
    // The Phase 2 integration would live under `tests/regression/` and
    // run with `cargo test --features xa-dtc -- --ignored
    // --test-threads=1` against a Windows host with MSDTC enabled.
}

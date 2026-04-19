//! Oracle XA / 2PC via the OCI XA library — Sprint 4.3c (deferred path).
//!
//! ## Status
//!
//! **Phase 1: dynamic-loading shim landed and unit-tested. Production
//! Oracle XA flows through [`crate::engine::xa_transaction`] using the
//! `DBMS_XA` PL/SQL package instead.**
//!
//! Oracle does not expose XA through the ODBC standard. Two
//! integration paths exist:
//!
//! - **`DBMS_XA` PL/SQL package** *(production)* — every Oracle 10g+
//!   ships a `SYS.DBMS_XA` package that exposes `XA_START / END /
//!   PREPARE / COMMIT / ROLLBACK` as ordinary callable SQL. The
//!   `apply_xa_*` matrix in [`crate::engine::xa_transaction`] uses
//!   this path because it works through any Oracle ODBC driver
//!   without requiring access to the underlying `OCIServer*` handle
//!   (which `odbc-api` does not expose). Recovery uses
//!   `DBA_PENDING_TRANSACTIONS`.
//! - **OCI XA library** *(this module, deferred)* — resolves the
//!   X/Open `xa_*` symbol set from `libclntsh.so` (Linux/macOS) or
//!   `oci.dll` (Windows) at runtime via `libloading`. Wiring this
//!   path into the `apply_xa_*` matrix would require sharing the OCI
//!   session with the ODBC connection (the OCI XA branch must run on
//!   the same physical session ODBC is using). Until `odbc-api`
//!   surfaces the underlying handle this stays as a scaffolded option
//!   — useful documentation of the OCI ABI and a possible target if
//!   we ever need OCI-only features the PL/SQL path can't reach.
//!
//! ## Build / activation
//!
//! - Compile with `--features xa-oci`. Without the feature the OCI
//!   shim is not built; Oracle XA still works via the `DBMS_XA` path
//!   in [`crate::engine::xa_transaction`].
//! - At runtime, the Oracle Instant Client must be on the dynamic-
//!   linker search path (`LD_LIBRARY_PATH` on Linux, `PATH` on
//!   Windows). If the library can't be found, [`load_oci`] returns
//!   `UnsupportedFeature` with an actionable message.
//! - The Oracle DB must have an XA_OPEN entry registered for the
//!   schema you're connecting as (typical: `XA_OPEN: ORACLE_XA+...`).
//!
//! ## Why dynamic loading
//!
//! Static linkage against `libclntsh` would force every consumer to
//! either ship Oracle Instant Client or skip our crate entirely. The
//! same trade-off Oracle's own JDBC driver settled on: load on demand,
//! fail with a clear error when the library is missing.

use crate::engine::xa_transaction::Xid;
use crate::error::{OdbcError, Result};
use std::ffi::c_int;
use std::os::raw::c_char;
use std::sync::OnceLock;

/// XID layout as defined by `oraxa.h` (the Oracle Instant Client
/// header). 192 bytes total: 4 (formatID) + 4 (gtrid_length) + 4
/// (bqual_length) + 128 (data).
///
/// `repr(C)` is mandatory — the OCI library reads/writes this struct
/// directly via FFI. The field order matches X/Open's `xid_t`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct OciXid {
    format_id: i32,
    gtrid_length: i32,
    bqual_length: i32,
    data: [c_char; 128],
}

impl OciXid {
    fn from_xid(xid: &Xid) -> Self {
        let mut data = [0_i8; 128];
        let g = xid.gtrid();
        let b = xid.bqual();
        // Concat gtrid || bqual into the 128-byte payload. Lengths
        // are validated by `Xid::new` to fit (1..=64 each, sum <= 128).
        for (i, &byte) in g.iter().enumerate() {
            data[i] = byte as i8;
        }
        for (i, &byte) in b.iter().enumerate() {
            data[g.len() + i] = byte as i8;
        }
        Self {
            format_id: xid.format_id(),
            gtrid_length: g.len() as i32,
            bqual_length: b.len() as i32,
            data,
        }
    }
}

/// X/Open XA flag constants. Mirrors `oraxa.h`. Only the subset we
/// actually emit is declared here.
mod xa_flags {
    use super::c_int;
    /// `xa_start`: begin a new branch.
    pub const TMNOFLAGS: c_int = 0;
    /// `xa_end`: branch is suspended (recoverable).
    #[allow(dead_code)] // reserved for future XA suspend/resume support
    pub const TMSUSPEND: c_int = 0x02000000;
    /// `xa_end`: branch is completed (success / failure to be decided).
    pub const TMSUCCESS: c_int = 0x04000000;
    /// `xa_commit`: 1RM optimisation — fuse prepare + commit.
    pub const TMONEPHASE: c_int = 0x40000000;
}

/// Function pointer table — populated lazily on first use via
/// [`load_oci`]. Each entry is a raw FFI signature mirroring the
/// `oraxa.h` declarations.
struct OciXaSymbols {
    // SAFETY: hold the Library alive for the whole process lifetime;
    // dropping it would invalidate every function pointer below.
    _lib: libloading::Library,
    xa_open: unsafe extern "C" fn(info: *const c_char, rmid: c_int, flags: c_int) -> c_int,
    xa_close: unsafe extern "C" fn(info: *const c_char, rmid: c_int, flags: c_int) -> c_int,
    xa_start: unsafe extern "C" fn(xid: *const OciXid, rmid: c_int, flags: c_int) -> c_int,
    xa_end: unsafe extern "C" fn(xid: *const OciXid, rmid: c_int, flags: c_int) -> c_int,
    xa_prepare: unsafe extern "C" fn(xid: *const OciXid, rmid: c_int, flags: c_int) -> c_int,
    xa_commit: unsafe extern "C" fn(xid: *const OciXid, rmid: c_int, flags: c_int) -> c_int,
    xa_rollback: unsafe extern "C" fn(xid: *const OciXid, rmid: c_int, flags: c_int) -> c_int,
    xa_recover:
        unsafe extern "C" fn(xids: *mut OciXid, count: c_int, rmid: c_int, flags: c_int) -> c_int,
}

// SAFETY: function pointers are FFI-safe to share across threads;
// the underlying OCI XA library is documented to be thread-safe
// when `OCI_THREADED` is set at OCIEnvCreate (the typical default).
unsafe impl Send for OciXaSymbols {}
unsafe impl Sync for OciXaSymbols {}

static OCI_SYMBOLS: OnceLock<std::result::Result<OciXaSymbols, String>> = OnceLock::new();

/// Resolve the OCI shared library and look up the XA symbol set.
/// Cached after first call so subsequent invocations are O(1).
fn load_oci() -> std::result::Result<&'static OciXaSymbols, String> {
    OCI_SYMBOLS
        .get_or_init(|| unsafe {
            // Try the canonical name on each platform; libloading
            // resolves via the standard dynamic-linker search path
            // (`LD_LIBRARY_PATH` on Linux, `DYLD_LIBRARY_PATH` on
            // macOS, `PATH` on Windows). Failure to find the library
            // is propagated as an actionable string error.
            let candidates: &[&str] = if cfg!(target_os = "windows") {
                &["oci.dll", "oraociei19.dll", "oraociei18.dll"]
            } else if cfg!(target_os = "macos") {
                &[
                    "libclntsh.dylib",
                    "libclntsh.dylib.19.1",
                    "libclntsh.dylib.18.1",
                ]
            } else {
                &["libclntsh.so", "libclntsh.so.19.1", "libclntsh.so.18.1"]
            };
            let mut last_err = String::new();
            let lib = candidates
                .iter()
                .find_map(|name| match libloading::Library::new(name) {
                    Ok(l) => Some(l),
                    Err(e) => {
                        last_err = format!("{}: {}", name, e);
                        None
                    }
                });
            let Some(lib) = lib else {
                return Err(format!(
                    "xa_oci: failed to load Oracle Instant Client. \
                     Tried {:?}; last error: {}. Install Oracle \
                     Instant Client and ensure the loader can find \
                     the library (LD_LIBRARY_PATH on Linux, PATH on \
                     Windows).",
                    candidates, last_err,
                ));
            };

            // Symbol lookup. Each `?` aborts the closure on the first
            // missing symbol — we collect into a String to match the
            // OnceLock signature.
            macro_rules! sym {
                ($name:literal) => {
                    match lib.get($name.as_bytes()) {
                        Ok(s) => *s,
                        Err(e) => {
                            return Err(format!(
                                "xa_oci: symbol {} not found in OCI library: {}",
                                $name, e,
                            ));
                        }
                    }
                };
            }

            let xa_open = sym!("xaosw"); // canonical OCI XA `xa_open`
            let xa_close = sym!("xaocl");
            let xa_start = sym!("xaostart");
            let xa_end = sym!("xaoend");
            let xa_prepare = sym!("xaoprep");
            let xa_commit = sym!("xaocommit");
            let xa_rollback = sym!("xaoroll");
            let xa_recover = sym!("xaorecover");

            Ok(OciXaSymbols {
                _lib: lib,
                xa_open,
                xa_close,
                xa_start,
                xa_end,
                xa_prepare,
                xa_commit,
                xa_rollback,
                xa_recover,
            })
        })
        .as_ref()
        .map_err(|e| e.clone())
}

fn ensure_loaded() -> Result<&'static OciXaSymbols> {
    load_oci().map_err(OdbcError::UnsupportedFeature)
}

/// Public entry point: open the XA resource manager `info` (typically
/// the connection string passed to Oracle's XA registration), then
/// `xa_start` a new branch with `xid`.
///
/// **Phase 1 caveat**: this performs the OCI XA bookkeeping (load
/// library + xa_open + xa_start) but the integration with the
/// existing `XaTransaction` lifecycle in `xa_transaction.rs`
/// (translating Phase 1 / Phase 2 calls to the OCI symbols) is
/// **Phase 2** of this sprint and tracked in
/// `FUTURE_IMPLEMENTATIONS.md` §4.3c.
///
/// Phase 1 deliverable: the dynamic-loading shim is correct,
/// reachable from the `xa-oci` feature, and falls back cleanly to
/// `UnsupportedFeature` when the OCI library isn't installed — so
/// hosts without Oracle Instant Client keep building.
pub fn begin_oci_branch(info: &str, xid: &Xid, rmid: c_int) -> Result<OciXaBranch> {
    let symbols = ensure_loaded()?;

    // Build a NUL-terminated copy of `info` for the C ABI.
    let info_c = std::ffi::CString::new(info).map_err(|_| {
        OdbcError::ValidationError("xa_oci: open string must not contain interior NULs".to_string())
    })?;

    // SAFETY: the function pointer was looked up by name from the OCI
    // library and matches the documented signature in oraxa.h.
    let rc = unsafe { (symbols.xa_open)(info_c.as_ptr(), rmid, xa_flags::TMNOFLAGS) };
    if rc != 0 {
        return Err(OdbcError::InternalError(format!(
            "xa_oci: xa_open failed with XA error code {} (see oraxa.h \
             XA_OK / XAER_* for the meaning)",
            rc,
        )));
    }

    let oci_xid = OciXid::from_xid(xid);
    let rc = unsafe { (symbols.xa_start)(&oci_xid, rmid, xa_flags::TMNOFLAGS) };
    if rc != 0 {
        // Best-effort xa_close to release the resource manager handle
        // we just opened. Failures here are logged; the original
        // xa_start error wins.
        let close_rc = unsafe { (symbols.xa_close)(info_c.as_ptr(), rmid, xa_flags::TMNOFLAGS) };
        if close_rc != 0 {
            log::warn!(
                "xa_oci: rollback xa_close after failed xa_start returned {}",
                close_rc,
            );
        }
        return Err(OdbcError::InternalError(format!(
            "xa_oci: xa_start failed with XA error code {}",
            rc,
        )));
    }

    Ok(OciXaBranch {
        info: info_c,
        rmid,
        oci_xid,
        symbols,
        terminated: false,
    })
}

/// Owned handle to a live OCI XA branch. Drop calls `xa_rollback +
/// xa_close` on a still-active branch; explicit termination via
/// [`prepare`](Self::prepare) → [`commit`](Self::commit) /
/// [`rollback`](Self::rollback) (or the [`commit_one_phase`](Self::commit_one_phase)
/// shortcut) is preferred so failures surface to the caller.
pub struct OciXaBranch {
    info: std::ffi::CString,
    rmid: c_int,
    oci_xid: OciXid,
    symbols: &'static OciXaSymbols,
    /// Set to `true` after a successful commit/rollback so Drop
    /// doesn't try to abort an already-finalised branch.
    terminated: bool,
}

impl OciXaBranch {
    /// `xa_end` (`TMSUCCESS`): mark the branch as completed and
    /// detached from the connection. Required before `xa_prepare`.
    fn end_success(&mut self) -> Result<()> {
        let rc = unsafe { (self.symbols.xa_end)(&self.oci_xid, self.rmid, xa_flags::TMSUCCESS) };
        if rc != 0 {
            return Err(OdbcError::InternalError(format!(
                "xa_oci: xa_end(TMSUCCESS) failed with XA error code {}",
                rc,
            )));
        }
        Ok(())
    }

    /// Phase 1 of 2PC.
    pub fn prepare(&mut self) -> Result<()> {
        self.end_success()?;
        let rc =
            unsafe { (self.symbols.xa_prepare)(&self.oci_xid, self.rmid, xa_flags::TMNOFLAGS) };
        if rc != 0 {
            return Err(OdbcError::InternalError(format!(
                "xa_oci: xa_prepare failed with XA error code {}",
                rc,
            )));
        }
        Ok(())
    }

    /// Phase 2 commit on a previously prepared branch.
    pub fn commit(mut self) -> Result<()> {
        let rc = unsafe { (self.symbols.xa_commit)(&self.oci_xid, self.rmid, xa_flags::TMNOFLAGS) };
        let close_rc =
            unsafe { (self.symbols.xa_close)(self.info.as_ptr(), self.rmid, xa_flags::TMNOFLAGS) };
        self.terminated = true;
        if rc != 0 {
            return Err(OdbcError::InternalError(format!(
                "xa_oci: xa_commit failed with XA error code {}",
                rc,
            )));
        }
        if close_rc != 0 {
            log::warn!(
                "xa_oci: xa_close after successful commit returned {}",
                close_rc,
            );
        }
        Ok(())
    }

    /// Phase 2 rollback on a prepared (or active) branch.
    pub fn rollback(mut self) -> Result<()> {
        let rc =
            unsafe { (self.symbols.xa_rollback)(&self.oci_xid, self.rmid, xa_flags::TMNOFLAGS) };
        let close_rc =
            unsafe { (self.symbols.xa_close)(self.info.as_ptr(), self.rmid, xa_flags::TMNOFLAGS) };
        self.terminated = true;
        if rc != 0 {
            return Err(OdbcError::InternalError(format!(
                "xa_oci: xa_rollback failed with XA error code {}",
                rc,
            )));
        }
        if close_rc != 0 {
            log::warn!("xa_oci: xa_close after rollback returned {}", close_rc,);
        }
        Ok(())
    }

    /// 1RM optimisation: `xa_end` + `xa_commit(TMONEPHASE)`. Skips
    /// the prepare-log write; only safe when this branch is the sole
    /// participant.
    pub fn commit_one_phase(mut self) -> Result<()> {
        self.end_success()?;
        let rc =
            unsafe { (self.symbols.xa_commit)(&self.oci_xid, self.rmid, xa_flags::TMONEPHASE) };
        let close_rc =
            unsafe { (self.symbols.xa_close)(self.info.as_ptr(), self.rmid, xa_flags::TMNOFLAGS) };
        self.terminated = true;
        if rc != 0 {
            return Err(OdbcError::InternalError(format!(
                "xa_oci: xa_commit(TMONEPHASE) failed with XA error code {}",
                rc,
            )));
        }
        if close_rc != 0 {
            log::warn!(
                "xa_oci: xa_close after one-phase commit returned {}",
                close_rc,
            );
        }
        Ok(())
    }
}

impl Drop for OciXaBranch {
    fn drop(&mut self) {
        if self.terminated {
            return;
        }
        // Best-effort: rollback + close. Failures are logged; we can't
        // propagate from Drop.
        let rc =
            unsafe { (self.symbols.xa_rollback)(&self.oci_xid, self.rmid, xa_flags::TMNOFLAGS) };
        if rc != 0 {
            log::warn!(
                "xa_oci Drop: xa_rollback returned {} on still-active branch",
                rc,
            );
        }
        let close_rc =
            unsafe { (self.symbols.xa_close)(self.info.as_ptr(), self.rmid, xa_flags::TMNOFLAGS) };
        if close_rc != 0 {
            log::warn!("xa_oci Drop: xa_close returned {}", close_rc);
        }
    }
}

/// `xa_recover`: list every XID currently in the `Prepared` state on
/// the OCI resource manager identified by `info` / `rmid`. The
/// caller-supplied `max` caps the buffer size; OCI returns at most
/// `max` XIDs per call.
pub fn recover_oci_xids(info: &str, rmid: c_int, max: usize) -> Result<Vec<Xid>> {
    let symbols = ensure_loaded()?;

    let info_c = std::ffi::CString::new(info).map_err(|_| {
        OdbcError::ValidationError("xa_oci: open string must not contain interior NULs".to_string())
    })?;

    // Open + recover + close. Recovery doesn't need an active branch,
    // but xa_open is required to bind the rmid to a live session.
    let rc = unsafe { (symbols.xa_open)(info_c.as_ptr(), rmid, xa_flags::TMNOFLAGS) };
    if rc != 0 {
        return Err(OdbcError::InternalError(format!(
            "xa_oci: xa_open(recover) failed with XA error code {}",
            rc,
        )));
    }

    let mut buffer: Vec<OciXid> = vec![
        OciXid {
            format_id: 0,
            gtrid_length: 0,
            bqual_length: 0,
            data: [0; 128],
        };
        max
    ];
    let count = unsafe {
        (symbols.xa_recover)(buffer.as_mut_ptr(), max as c_int, rmid, xa_flags::TMNOFLAGS)
    };

    let close_rc = unsafe { (symbols.xa_close)(info_c.as_ptr(), rmid, xa_flags::TMNOFLAGS) };
    if close_rc != 0 {
        log::warn!("xa_oci: xa_close after recover returned {}", close_rc,);
    }

    if count < 0 {
        return Err(OdbcError::InternalError(format!(
            "xa_oci: xa_recover failed with XA error code {}",
            count,
        )));
    }
    let mut out = Vec::with_capacity(count as usize);
    for oxid in buffer.iter().take(count as usize) {
        let g_len = oxid.gtrid_length as usize;
        let b_len = oxid.bqual_length as usize;
        if g_len == 0 || g_len + b_len > 128 {
            continue;
        }
        let gtrid: Vec<u8> = oxid.data[..g_len].iter().map(|&b| b as u8).collect();
        let bqual: Vec<u8> = oxid.data[g_len..g_len + b_len]
            .iter()
            .map(|&b| b as u8)
            .collect();
        if let Ok(xid) = Xid::new(oxid.format_id, gtrid, bqual) {
            out.push(xid);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------
    // OciXid layout — pinned so future struct edits can't silently
    // break the FFI contract with the OCI library.
    // -----------------------------------------------------------------

    #[test]
    fn oci_xid_layout_matches_oraxa_h() {
        // 4 (formatID) + 4 (gtrid_length) + 4 (bqual_length) + 128 (data)
        // == 140 bytes total. The struct is `repr(C)`, so size is
        // deterministic across platforms.
        assert_eq!(std::mem::size_of::<OciXid>(), 4 + 4 + 4 + 128);
        assert_eq!(std::mem::align_of::<OciXid>(), 4);
    }

    #[test]
    fn oci_xid_from_xid_packs_gtrid_then_bqual() {
        let xid = Xid::new(7, vec![0xAA, 0xBB, 0xCC], vec![0x11, 0x22]).unwrap();
        let oci = OciXid::from_xid(&xid);
        assert_eq!(oci.format_id, 7);
        assert_eq!(oci.gtrid_length, 3);
        assert_eq!(oci.bqual_length, 2);
        // First 3 bytes = gtrid, next 2 = bqual, rest = zeroes.
        assert_eq!(oci.data[0] as u8, 0xAA);
        assert_eq!(oci.data[1] as u8, 0xBB);
        assert_eq!(oci.data[2] as u8, 0xCC);
        assert_eq!(oci.data[3] as u8, 0x11);
        assert_eq!(oci.data[4] as u8, 0x22);
        assert_eq!(oci.data[5] as u8, 0);
        assert_eq!(oci.data[127] as u8, 0);
    }

    #[test]
    fn oci_xid_from_xid_handles_max_size_components() {
        // 64 + 64 = 128 bytes; should fit exactly.
        let xid = Xid::new(0, vec![b'g'; 64], vec![b'b'; 64]).unwrap();
        let oci = OciXid::from_xid(&xid);
        assert_eq!(oci.gtrid_length, 64);
        assert_eq!(oci.bqual_length, 64);
        assert_eq!(oci.data[0] as u8, b'g');
        assert_eq!(oci.data[63] as u8, b'g');
        assert_eq!(oci.data[64] as u8, b'b');
        assert_eq!(oci.data[127] as u8, b'b');
    }

    #[test]
    fn oci_xid_from_xid_handles_empty_bqual() {
        let xid = Xid::new(1, vec![0xFF], vec![]).unwrap();
        let oci = OciXid::from_xid(&xid);
        assert_eq!(oci.gtrid_length, 1);
        assert_eq!(oci.bqual_length, 0);
        assert_eq!(oci.data[0] as u8, 0xFF);
        assert_eq!(oci.data[1] as u8, 0);
    }

    #[test]
    fn xa_flag_constants_match_oraxa_h() {
        // Pinned exactly. If Oracle ever renumbers these flags
        // (extremely unlikely — they're frozen since X/Open 1991)
        // this test will catch it.
        assert_eq!(xa_flags::TMNOFLAGS, 0);
        assert_eq!(xa_flags::TMSUSPEND, 0x02000000);
        assert_eq!(xa_flags::TMSUCCESS, 0x04000000);
        assert_eq!(xa_flags::TMONEPHASE, 0x40000000);
    }

    #[test]
    fn load_oci_returns_unsupported_when_library_missing() {
        // On a host without Oracle Instant Client, loading must
        // surface as `UnsupportedFeature` with an actionable message.
        // We can't *force* that (the host might have OCI), so we just
        // assert the load result either is `Ok` (OCI is present) or
        // is an `UnsupportedFeature` carrying our actionable wording.
        match ensure_loaded() {
            Ok(_) => {
                // OCI present on this host — nothing else to assert.
            }
            Err(OdbcError::UnsupportedFeature(msg)) => {
                assert!(
                    msg.contains("xa_oci")
                        && (msg.contains("Oracle Instant Client") || msg.contains("symbol")),
                    "error message must point at the dependency: {msg}"
                );
            }
            Err(other) => panic!("unexpected error variant: {other:?}"),
        }
    }
}

//! X/Open XA distributed transaction support — Sprint 4.3.
//!
//! Implements the **Two-Phase Commit (2PC)** lifecycle on top of ODBC
//! using each engine's native SQL-level XA grammar. The cross-vendor
//! abstraction lives here; per-engine SQL emission lives in
//! [`apply_xa_start`], [`apply_xa_end`], [`apply_xa_prepare`],
//! [`apply_xa_commit`], [`apply_xa_rollback`] and [`apply_xa_recover`].
//!
//! ## Engine matrix
//!
//! | Engine                | Mechanism                                  | Status            |
//! | --------------------- | ------------------------------------------ | ----------------- |
//! | PostgreSQL            | SQL: `PREPARE TRANSACTION` + `pg_prepared_xacts` | ✅ implemented |
//! | MySQL / MariaDB       | SQL: `XA START / END / PREPARE / COMMIT / ROLLBACK / RECOVER` | ✅ implemented |
//! | DB2                   | SQL: native `XA*` family                   | ✅ implemented    |
//! | SQL Server            | Requires MSDTC enlistment (Windows COM, `SQL_ATTR_ENLIST_IN_DTC` + `ITransaction*`) | ⚠️ stub — returns `UnsupportedFeature` with TODO; planned as a follow-up that needs the `windows-sys` crate and a separate build configuration |
//! | Oracle                | PL/SQL: `DBMS_XA` package (`SYS.DBMS_XA_XID`, `XA_START / END / PREPARE / COMMIT / ROLLBACK`); recovery via `DBA_PENDING_TRANSACTIONS` | ✅ implemented (10g+) — needs `EXECUTE` on `DBMS_XA` plus `FORCE [ANY] TRANSACTION` |
//! | SQLite / Snowflake / others | No 2PC support                       | ❌ rejected with `UnsupportedFeature` |
//!
//! Note on Oracle: an alternative path through Oracle's OCI XA library
//! (`xaoSvcCtx` / `oraxa.h`) is scaffolded in [`crate::engine::xa_oci`]
//! behind the `xa-oci` Cargo feature. Production deployments use the
//! `DBMS_XA` PL/SQL path because it works through any Oracle ODBC
//! driver without requiring access to the underlying `OCIServer*`
//! handle (which `odbc-api` does not expose). The OCI shim is kept
//! as a future option if the underlying handle ever becomes
//! reachable.
//!
//! ## XID encoding
//!
//! The X/Open XID is a 192-byte structure with three fields: a 32-bit
//! `format_id`, a 1..64-byte global transaction id (`gtrid`) and a
//! 0..64-byte branch qualifier (`bqual`).
//!
//! Each engine demands a different SQL-level spelling:
//!
//! - **PostgreSQL** accepts a single arbitrary string identifier.
//!   We canonicalise as `"<format_id>_<gtrid_hex>_<bqual_hex>"` so
//!   the original components round-trip through `pg_prepared_xacts`.
//! - **MySQL / MariaDB** uses three positional arguments:
//!   `XA START 'gtrid', 'bqual', formatID`. We pass the components
//!   directly, hex-encoded to keep the SQL ASCII-clean.
//! - **DB2** matches MySQL's three-argument grammar.
//!
//! See [`Xid::encode_postgres`], [`Xid::encode_mysql_components`] and
//! [`Xid::decode_postgres`].
//!
//! ## State machine
//!
//! ```text
//!                start              end                prepare
//!     [None] ──────────▶ [Active] ──────▶ [Idle] ─────────────▶ [Prepared]
//!                          │                │                       │
//!                          │ rollback       │ rollback              │ commit_prepared
//!                          ▼                ▼                       ▼
//!                       [RolledBack]   [RolledBack]              [Committed]
//!                                                                    or
//!                                                                [RolledBack]
//! ```
//!
//! `commit_one_phase` is a 1RM optimisation that fuses
//! `prepare → commit_prepared` for the case where the resource manager
//! is the only RM in the transaction. Avoids the disk write of the
//! prepare log; valid only when the caller is sure no other RM
//! enlisted.

use crate::engine::core::{
    ENGINE_DB2, ENGINE_MARIADB, ENGINE_MYSQL, ENGINE_ORACLE, ENGINE_POSTGRES, ENGINE_SQLSERVER,
    ENGINE_UNKNOWN,
};
use crate::engine::dbms_info::DbmsInfo;
use crate::error::{OdbcError, Result};
use crate::handles::SharedHandleManager;
use std::sync::{Arc, Mutex};

// XID size limits per X/Open. We enforce them at construction so a
// malformed XID can never reach the engine — every backend rejects
// oversize gtrid/bqual but with cryptic messages.
const XID_MAX_GTRID_LEN: usize = 64;
const XID_MAX_BQUAL_LEN: usize = 64;

/// Global transaction identifier (X/Open XA `XID`).
///
/// The 32-bit `format_id` is application-defined; common values are
/// `0` (default) or `0x1B` (the IBM/JTA convention). `gtrid` is the
/// global transaction id (1..64 bytes); `bqual` is the branch
/// qualifier (0..64 bytes). All three together must be unique within
/// the recovery set of every participating Resource Manager.
///
/// Construct via [`Xid::new`] (validating) or [`Xid::for_test`]
/// (no-op constructor for unit tests).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Xid {
    format_id: i32,
    gtrid: Vec<u8>,
    bqual: Vec<u8>,
}

impl Xid {
    /// Construct a new XID, validating the `gtrid` / `bqual` lengths
    /// against the X/Open limits (1..=64 bytes for `gtrid`,
    /// 0..=64 bytes for `bqual`). Empty `gtrid` is rejected because
    /// every RM treats it as a malformed transaction id.
    pub fn new(format_id: i32, gtrid: Vec<u8>, bqual: Vec<u8>) -> Result<Self> {
        if gtrid.is_empty() {
            return Err(OdbcError::ValidationError(
                "Xid: gtrid must be non-empty (1..=64 bytes)".to_string(),
            ));
        }
        if gtrid.len() > XID_MAX_GTRID_LEN {
            return Err(OdbcError::ValidationError(format!(
                "Xid: gtrid is {} bytes; X/Open limit is {}",
                gtrid.len(),
                XID_MAX_GTRID_LEN,
            )));
        }
        if bqual.len() > XID_MAX_BQUAL_LEN {
            return Err(OdbcError::ValidationError(format!(
                "Xid: bqual is {} bytes; X/Open limit is {}",
                bqual.len(),
                XID_MAX_BQUAL_LEN,
            )));
        }
        Ok(Self {
            format_id,
            gtrid,
            bqual,
        })
    }

    pub fn format_id(&self) -> i32 {
        self.format_id
    }

    pub fn gtrid(&self) -> &[u8] {
        &self.gtrid
    }

    pub fn bqual(&self) -> &[u8] {
        &self.bqual
    }

    /// Canonical PostgreSQL identifier:
    /// `"<format_id>_<gtrid_hex>_<bqual_hex>"`. Round-trippable via
    /// [`Xid::decode_postgres`]. The hex encoding keeps the
    /// identifier ASCII-clean so it survives `pg_prepared_xacts`
    /// without quoting surprises.
    pub fn encode_postgres(&self) -> String {
        format!(
            "{}_{}_{}",
            self.format_id,
            hex_encode(&self.gtrid),
            hex_encode(&self.bqual),
        )
    }

    /// Inverse of [`Xid::encode_postgres`]. Returns `None` for any
    /// input that doesn't match the canonical shape — including XIDs
    /// that PostgreSQL knows about but were prepared by another
    /// client using a different naming scheme.
    pub fn decode_postgres(s: &str) -> Option<Self> {
        let mut parts = s.splitn(3, '_');
        let format_id_str = parts.next()?;
        let gtrid_hex = parts.next()?;
        let bqual_hex = parts.next()?;
        let format_id: i32 = format_id_str.parse().ok()?;
        let gtrid = hex_decode(gtrid_hex)?;
        let bqual = hex_decode(bqual_hex)?;
        Self::new(format_id, gtrid, bqual).ok()
    }

    /// MySQL / MariaDB / DB2 split the XID into three positional
    /// arguments: `XA START 'gtrid', 'bqual', formatID`. We
    /// hex-encode `gtrid` / `bqual` so the SQL stays ASCII-clean
    /// regardless of the byte content (which X/Open allows to be
    /// arbitrary binary).
    ///
    /// Returns `(gtrid_hex, bqual_hex, format_id)`.
    pub fn encode_mysql_components(&self) -> (String, String, i32) {
        (
            hex_encode(&self.gtrid),
            hex_encode(&self.bqual),
            self.format_id,
        )
    }

    /// Inverse of [`Xid::encode_mysql_components`]. Used by
    /// [`apply_xa_recover`] to rebuild the XID list returned by
    /// `XA RECOVER`.
    pub fn decode_mysql_components(
        gtrid_hex: &str,
        bqual_hex: &str,
        format_id: i32,
    ) -> Option<Self> {
        let gtrid = hex_decode(gtrid_hex)?;
        let bqual = hex_decode(bqual_hex)?;
        Self::new(format_id, gtrid, bqual).ok()
    }

    /// Oracle `DBMS_XA` PL/SQL takes a `SYS.DBMS_XA_XID(formatid INTEGER,
    /// gtrid RAW(64), bqual RAW(64))` constructor. We pass the binary
    /// components as `HEXTORAW('<uppercase hex>')` literals — uppercase
    /// because Oracle's own `RAWTOHEX` returns uppercase, which keeps
    /// recovery round-trips byte-identical.
    ///
    /// Returns `(format_id, gtrid_hex_upper, bqual_hex_upper)`.
    pub fn encode_oracle_components(&self) -> (i32, String, String) {
        (
            self.format_id,
            hex_encode_upper(&self.gtrid),
            hex_encode_upper(&self.bqual),
        )
    }

    /// Inverse of [`Xid::encode_oracle_components`]. Hex parsing is
    /// case-insensitive so we round-trip both our own `HEXTORAW`
    /// literals and the uppercase form returned by Oracle's
    /// `RAWTOHEX(globalid)` in `DBA_PENDING_TRANSACTIONS`.
    pub fn decode_oracle_components(
        format_id: i32,
        gtrid_hex: &str,
        bqual_hex: &str,
    ) -> Option<Self> {
        let gtrid = hex_decode(gtrid_hex)?;
        let bqual = hex_decode(bqual_hex)?;
        Self::new(format_id, gtrid, bqual).ok()
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX_LUT[(b >> 4) as usize] as char);
        out.push(HEX_LUT[(b & 0x0F) as usize] as char);
    }
    out
}

const HEX_LUT: &[u8; 16] = b"0123456789abcdef";
const HEX_LUT_UPPER: &[u8; 16] = b"0123456789ABCDEF";

fn hex_encode_upper(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX_LUT_UPPER[(b >> 4) as usize] as char);
        out.push(HEX_LUT_UPPER[(b & 0x0F) as usize] as char);
    }
    out
}

fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    for chunk in bytes.chunks_exact(2) {
        let hi = hex_nibble(chunk[0])?;
        let lo = hex_nibble(chunk[1])?;
        out.push((hi << 4) | lo);
    }
    Some(out)
}

fn hex_nibble(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// State machine for an active XA transaction branch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum XaState {
    /// Transaction has not been started yet (handle is fresh).
    None,
    /// `xa_start` succeeded; SQL on the connection now joins the branch.
    Active,
    /// `xa_end` succeeded; the branch is detached from the connection
    /// and ready to `xa_prepare`. Cannot run further SQL on the branch.
    Idle,
    /// `xa_prepare` succeeded; the branch is heuristically committable
    /// (Phase 1 done). The Transaction Manager decides Phase 2.
    Prepared,
    /// `xa_commit` succeeded.
    Committed,
    /// `xa_rollback` succeeded, or any failure-induced rollback fired.
    RolledBack,
    /// A non-recoverable failure left the branch in an undefined state.
    /// Recovery via `xa_recover` is the only way out.
    Failed,
}

/// An active XA transaction branch on a single Resource Manager.
///
/// Built via [`XaTransaction::start`]. Drive through the state machine
/// with [`XaTransaction::end`] (returns a [`PreparingXa`] handle), then
/// [`PreparingXa::prepare`] (returns a [`PreparedXa`] handle), then
/// [`PreparedXa::commit`] / [`PreparedXa::rollback`].
///
/// The 1RM optimisation [`XaTransaction::commit_one_phase`] fuses
/// prepare + commit; use only when this RM is the sole participant.
pub struct XaTransaction {
    handles: SharedHandleManager,
    conn_id: u32,
    xid: Xid,
    engine_id: String,
    state: Arc<Mutex<XaState>>,
}

/// Intermediate state after [`XaTransaction::end`]. Caller must either
/// [`prepare`](PreparingXa::prepare) (Phase 1 of 2PC) or
/// [`rollback`](PreparingXa::rollback) immediately.
pub struct PreparingXa {
    inner: XaTransaction,
}

/// Heuristically committable branch — Phase 1 of 2PC has succeeded.
/// Caller drives Phase 2 with [`PreparedXa::commit`] or
/// [`PreparedXa::rollback`]. The handle survives process restart
/// thanks to `xa_recover`; see [`recover_prepared_xids`].
pub struct PreparedXa {
    handles: SharedHandleManager,
    conn_id: u32,
    xid: Xid,
    engine_id: String,
    state: Arc<Mutex<XaState>>,
}

impl XaTransaction {
    /// Begin an XA transaction branch on `conn_id` with global
    /// identifier `xid`. Fails with [`OdbcError::UnsupportedFeature`]
    /// for engines without SQL-level XA (SQL Server, Oracle, SQLite,
    /// Snowflake — see the matrix in this module's doc).
    pub fn start(handles: SharedHandleManager, conn_id: u32, xid: Xid) -> Result<Self> {
        let engine_id = detect_engine_id(&handles, conn_id);

        let conn_arc = {
            let h = handles
                .lock()
                .map_err(|_| OdbcError::InternalError("Failed to lock handles".to_string()))?;
            h.get_connection(conn_id)?
        };
        let mut conn = conn_arc
            .lock()
            .map_err(|_| OdbcError::InternalError("Failed to lock connection".to_string()))?;

        // Disable autocommit so the subsequent SQL joins the XA branch
        // instead of running in implicit single-statement transactions.
        conn.connection_mut()
            .set_autocommit(false)
            .map_err(OdbcError::from)?;

        apply_xa_start(conn.connection_mut(), &engine_id, &xid)?;

        Ok(Self {
            handles,
            conn_id,
            xid,
            engine_id,
            state: Arc::new(Mutex::new(XaState::Active)),
        })
    }

    pub fn xid(&self) -> &Xid {
        &self.xid
    }

    pub fn state(&self) -> XaState {
        self.state.lock().map(|s| *s).unwrap_or(XaState::Failed)
    }

    /// `xa_end`: detach the branch from the connection. After this
    /// the connection can be reused for other work or for
    /// `xa_prepare` on this branch.
    pub fn end(self) -> Result<PreparingXa> {
        self.assert_state(XaState::Active, "end")?;
        self.run_on_conn(apply_xa_end)?;
        *self.state.lock().unwrap() = XaState::Idle;
        Ok(PreparingXa { inner: self })
    }

    /// 1RM optimisation: fuse `prepare → commit_prepared` for the
    /// case where this RM is the sole participant. Avoids the disk
    /// write of the prepare log. **Only safe when no other RM has
    /// enlisted in the same global transaction.**
    pub fn commit_one_phase(self) -> Result<()> {
        self.assert_state(XaState::Active, "commit_one_phase")?;
        // Engine semantics: ONE_PHASE flag on `xa_commit`. The SQL-level
        // backends emit `XA END` followed immediately by
        // `XA COMMIT ... ONE PHASE` (MySQL/DB2) or by the
        // PostgreSQL plain `COMMIT` (the txn was never PREPAREd).
        self.run_on_conn(apply_xa_end)?;
        let r = self.run_on_conn(|conn, engine_id, xid| {
            apply_xa_commit(conn, engine_id, xid, /* one_phase = */ true)
        });
        let restore_autocommit = self.try_restore_autocommit();
        match (r, restore_autocommit) {
            (Ok(()), _) => {
                *self.state.lock().unwrap() = XaState::Committed;
                Ok(())
            }
            (Err(e), _) => {
                *self.state.lock().unwrap() = XaState::Failed;
                Err(e)
            }
        }
    }

    /// Roll back an Active branch (no PREPARE was issued). Equivalent
    /// to `xa_end` + `xa_rollback`. After this call the branch is
    /// gone — there is no recovery path because no prepare-log entry
    /// exists.
    pub fn rollback(self) -> Result<()> {
        self.assert_state(XaState::Active, "rollback")?;
        let _ = self.run_on_conn(apply_xa_end);
        let r = self.run_on_conn(apply_xa_rollback);
        let _ = self.try_restore_autocommit();
        match r {
            Ok(()) => {
                *self.state.lock().unwrap() = XaState::RolledBack;
                Ok(())
            }
            Err(e) => {
                *self.state.lock().unwrap() = XaState::Failed;
                Err(e)
            }
        }
    }

    fn assert_state(&self, expected: XaState, op: &str) -> Result<()> {
        let actual = self.state.lock().map(|s| *s).unwrap_or(XaState::Failed);
        if actual != expected {
            return Err(OdbcError::ValidationError(format!(
                "XaTransaction::{op}: expected state {:?}, got {:?}",
                expected, actual,
            )));
        }
        Ok(())
    }

    fn run_on_conn<F, T>(&self, f: F) -> Result<T>
    where
        F: FnOnce(&mut odbc_api::Connection<'static>, &str, &Xid) -> Result<T>,
    {
        let conn_arc = {
            let h = self
                .handles
                .lock()
                .map_err(|_| OdbcError::InternalError("Failed to lock handles".to_string()))?;
            h.get_connection(self.conn_id)?
        };
        let mut conn = conn_arc
            .lock()
            .map_err(|_| OdbcError::InternalError("Failed to lock connection".to_string()))?;
        f(conn.connection_mut(), &self.engine_id, &self.xid)
    }

    fn try_restore_autocommit(&self) -> Result<()> {
        // Best-effort: matches the discipline of regular Transaction
        // (B7 fix in v3.1). Logging happens at the call site.
        let conn_arc = {
            let h = self
                .handles
                .lock()
                .map_err(|_| OdbcError::InternalError("Failed to lock handles".to_string()))?;
            h.get_connection(self.conn_id)?
        };
        let mut conn = conn_arc
            .lock()
            .map_err(|_| OdbcError::InternalError("Failed to lock connection".to_string()))?;
        if let Err(e) = conn.connection_mut().set_autocommit(true) {
            log::error!(
                "XaTransaction: failed to restore autocommit on conn_id {}: {e}",
                self.conn_id
            );
        }
        Ok(())
    }
}

impl Drop for XaTransaction {
    fn drop(&mut self) {
        let s = self.state.lock().map(|s| *s).unwrap_or(XaState::Failed);
        if s == XaState::Active || s == XaState::Idle {
            log::warn!(
                "XaTransaction(xid = {:?}) on conn_id {} dropped without commit/rollback — \
                 attempting auto-rollback. State was {:?}",
                self.xid,
                self.conn_id,
                s,
            );
            // Best-effort rollback. We can't propagate errors from Drop;
            // the warn! above plus any structured error in the engine
            // logs is the only signal.
            let _ = self.run_on_conn(|c, e, x| {
                let _ = apply_xa_end(c, e, x);
                apply_xa_rollback(c, e, x)
            });
            let _ = self.try_restore_autocommit();
        }
    }
}

impl PreparingXa {
    /// `xa_prepare`: Phase 1 of 2PC. On success the branch becomes
    /// **heuristically committable** — its outcome survives a process
    /// crash and can be resolved later via [`recover_prepared_xids`].
    pub fn prepare(self) -> Result<PreparedXa> {
        let inner = self.inner;
        inner.assert_state(XaState::Idle, "prepare")?;
        let r = inner.run_on_conn(apply_xa_prepare);
        match r {
            Ok(()) => {
                *inner.state.lock().unwrap() = XaState::Prepared;
                let _ = inner.try_restore_autocommit();
                Ok(PreparedXa {
                    handles: inner.handles.clone(),
                    conn_id: inner.conn_id,
                    xid: inner.xid.clone(),
                    engine_id: inner.engine_id.clone(),
                    state: inner.state.clone(),
                })
            }
            Err(e) => {
                *inner.state.lock().unwrap() = XaState::Failed;
                let _ = inner.try_restore_autocommit();
                Err(e)
            }
        }
    }

    /// Roll back without preparing — equivalent to
    /// [`XaTransaction::rollback`] but valid in the `Idle` state too.
    pub fn rollback(self) -> Result<()> {
        let inner = self.inner;
        inner.assert_state(XaState::Idle, "rollback")?;
        let r = inner.run_on_conn(apply_xa_rollback);
        let _ = inner.try_restore_autocommit();
        match r {
            Ok(()) => {
                *inner.state.lock().unwrap() = XaState::RolledBack;
                Ok(())
            }
            Err(e) => {
                *inner.state.lock().unwrap() = XaState::Failed;
                Err(e)
            }
        }
    }
}

impl PreparedXa {
    pub fn xid(&self) -> &Xid {
        &self.xid
    }

    /// `xa_commit` (Phase 2): finalise the prepared branch. Returns
    /// success only when the engine confirmed the commit hit stable
    /// storage.
    pub fn commit(self) -> Result<()> {
        self.assert_state(XaState::Prepared, "commit")?;
        let r = self.run_on_conn(|c, e, x| apply_xa_commit(c, e, x, false));
        match r {
            Ok(()) => {
                *self.state.lock().unwrap() = XaState::Committed;
                Ok(())
            }
            Err(e) => {
                *self.state.lock().unwrap() = XaState::Failed;
                Err(e)
            }
        }
    }

    /// `xa_rollback` (Phase 2): roll back the prepared branch.
    /// PostgreSQL routes through `ROLLBACK PREPARED '<xid>'` because
    /// the prepare-log entry outlives the connection; the SQL-XA
    /// family (MySQL/MariaDB/DB2) reuses `XA ROLLBACK`.
    pub fn rollback(self) -> Result<()> {
        self.assert_state(XaState::Prepared, "rollback")?;
        let r = self.run_on_conn(apply_xa_rollback_prepared);
        match r {
            Ok(()) => {
                *self.state.lock().unwrap() = XaState::RolledBack;
                Ok(())
            }
            Err(e) => {
                *self.state.lock().unwrap() = XaState::Failed;
                Err(e)
            }
        }
    }

    fn assert_state(&self, expected: XaState, op: &str) -> Result<()> {
        let actual = self.state.lock().map(|s| *s).unwrap_or(XaState::Failed);
        if actual != expected {
            return Err(OdbcError::ValidationError(format!(
                "PreparedXa::{op}: expected state {:?}, got {:?}",
                expected, actual,
            )));
        }
        Ok(())
    }

    fn run_on_conn<F, T>(&self, f: F) -> Result<T>
    where
        F: FnOnce(&mut odbc_api::Connection<'static>, &str, &Xid) -> Result<T>,
    {
        let conn_arc = {
            let h = self
                .handles
                .lock()
                .map_err(|_| OdbcError::InternalError("Failed to lock handles".to_string()))?;
            h.get_connection(self.conn_id)?
        };
        let mut conn = conn_arc
            .lock()
            .map_err(|_| OdbcError::InternalError("Failed to lock connection".to_string()))?;
        f(conn.connection_mut(), &self.engine_id, &self.xid)
    }
}

/// `xa_recover`: list every XID currently in the `Prepared` state on
/// the resource manager. The Transaction Manager calls this after
/// crash recovery to learn which prepared branches still need a
/// Phase 2 decision (commit or rollback).
pub fn recover_prepared_xids(handles: SharedHandleManager, conn_id: u32) -> Result<Vec<Xid>> {
    let engine_id = detect_engine_id(&handles, conn_id);
    let conn_arc = {
        let h = handles
            .lock()
            .map_err(|_| OdbcError::InternalError("Failed to lock handles".to_string()))?;
        h.get_connection(conn_id)?
    };
    let mut conn = conn_arc
        .lock()
        .map_err(|_| OdbcError::InternalError("Failed to lock connection".to_string()))?;
    apply_xa_recover(conn.connection_mut(), &engine_id)
}

/// Resume a previously prepared XID — rebuilds a [`PreparedXa`] handle
/// for crash-recovery scenarios where the original `XaTransaction`
/// instance no longer exists.
///
/// Use [`recover_prepared_xids`] to discover the candidate XIDs first.
/// The returned handle goes straight to Phase 2: caller chooses
/// [`PreparedXa::commit`] or [`PreparedXa::rollback`] per the
/// Transaction Manager's recovery decision.
pub fn resume_prepared(handles: SharedHandleManager, conn_id: u32, xid: Xid) -> Result<PreparedXa> {
    let engine_id = detect_engine_id(&handles, conn_id);
    Ok(PreparedXa {
        handles,
        conn_id,
        xid,
        engine_id,
        state: Arc::new(Mutex::new(XaState::Prepared)),
    })
}

/// Best-effort engine detection. Falls back to `unknown` on any
/// `SQLGetInfo` failure so the SQL emitter sees a stable id and
/// returns a clean `UnsupportedFeature` instead of a chained error.
fn detect_engine_id(handles: &SharedHandleManager, conn_id: u32) -> String {
    DbmsInfo::detect_for_conn_id(handles, conn_id)
        .map(|info| info.engine)
        .unwrap_or_else(|_| ENGINE_UNKNOWN.to_string())
}

// -------------------------------------------------------------------------
// Oracle DBMS_XA helpers
// -------------------------------------------------------------------------

/// Build a `SYS.DBMS_XA_XID(formatid, HEXTORAW('gtrid'), HEXTORAW('bqual'))`
/// constructor literal. The hex form is uppercase to round-trip with
/// Oracle's `RAWTOHEX` output in `DBA_PENDING_TRANSACTIONS`.
fn oracle_xid_literal(xid: &Xid) -> String {
    let (fmt, g, b) = xid.encode_oracle_components();
    format!(
        "SYS.DBMS_XA_XID({fmt}, HEXTORAW('{g}'), HEXTORAW('{b}'))",
        fmt = fmt,
        g = g,
        b = b,
    )
}

/// Wrap a single `DBMS_XA.*` call in a PL/SQL block that converts a
/// non-zero return code into an `ORA-20100`. Optionally tolerates
/// specific extra return codes (the typical case is `XA_RDONLY=3` on
/// `XA_PREPARE`, where the branch did no DML and is auto-completed).
///
/// The block prefixes the surfaced rc with a sentinel marker the
/// caller can grep for; the engine_id is included so the error path
/// makes the source obvious in a multi-RM transaction.
fn oracle_xa_block(call: &str, allow_rcs: &[i32]) -> String {
    // Build an `IF rc <> 0 AND rc <> R1 AND rc <> R2 ... THEN raise`
    // guard. Empty allow_rcs collapses to `IF rc <> 0 THEN raise` so
    // any non-zero return is fatal. The PL/SQL block converts the
    // surfaced rc into ORA-20100 so the ODBC error path is uniform.
    let mut allow_clause = String::new();
    for rc in allow_rcs {
        allow_clause.push_str(&format!(" AND rc <> {}", rc));
    }
    format!(
        "BEGIN DECLARE rc PLS_INTEGER; BEGIN rc := {call}; \
         IF rc <> 0{allow_clause} THEN \
           RAISE_APPLICATION_ERROR(-20100, 'DBMS_XA rc=' || rc); \
         END IF; END; END;",
        call = call,
        allow_clause = allow_clause,
    )
}

/// `XAER_NOTA = -4` (the xid is not in the engine's known set).
/// Surfaces after a read-only `XA_PREPARE` (rc=3) auto-completes the
/// branch — Oracle silently drops it so the subsequent `XA_COMMIT`
/// can't find it. We treat both paths as success at the
/// [`XaTransaction`] layer; see `apply_xa_prepare` for context.
const ORACLE_XA_RDONLY: i32 = 3;
#[allow(dead_code)]
const ORACLE_XAER_NOTA: i32 = -4;

// -------------------------------------------------------------------------
// Per-engine SQL emitters
// -------------------------------------------------------------------------

fn apply_xa_start(
    conn: &mut odbc_api::Connection<'static>,
    engine_id: &str,
    xid: &Xid,
) -> Result<()> {
    match engine_id {
        ENGINE_POSTGRES => {
            // PostgreSQL has no `XA START` — every transaction is the
            // implicit branch. We still emit `BEGIN` to make the txn
            // boundary explicit (autocommit was turned off above).
            conn.execute("BEGIN", (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            let (g, b, f) = xid.encode_mysql_components();
            let sql = if b.is_empty() {
                format!("XA START '{}', '', {}", g, f)
            } else {
                format!("XA START '{}', '{}', {}", g, b, f)
            };
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // DBMS_XA.XA_START(xid, TMNOFLAGS) attaches the current
            // session to a new branch. The PL/SQL helper wraps the
            // call in an exception-translating block so a non-zero rc
            // surfaces as an ODBC error instead of silently winning.
            let sql = oracle_xa_block(
                &format!(
                    "DBMS_XA.XA_START({}, DBMS_XA.TMNOFLAGS)",
                    oracle_xid_literal(xid),
                ),
                &[],
            );
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

fn apply_xa_end(
    conn: &mut odbc_api::Connection<'static>,
    engine_id: &str,
    xid: &Xid,
) -> Result<()> {
    match engine_id {
        ENGINE_POSTGRES => {
            // No-op for PG — `xa_end` semantics are folded into
            // `xa_prepare` (PREPARE TRANSACTION ...).
            Ok(())
        }
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            let (g, b, f) = xid.encode_mysql_components();
            let sql = if b.is_empty() {
                format!("XA END '{}', '', {}", g, f)
            } else {
                format!("XA END '{}', '{}', {}", g, b, f)
            };
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // DBMS_XA.XA_END(xid, TMSUCCESS) detaches the session from
            // the branch. Required before XA_PREPARE per X/Open.
            let sql = oracle_xa_block(
                &format!(
                    "DBMS_XA.XA_END({}, DBMS_XA.TMSUCCESS)",
                    oracle_xid_literal(xid),
                ),
                &[],
            );
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

fn apply_xa_prepare(
    conn: &mut odbc_api::Connection<'static>,
    engine_id: &str,
    xid: &Xid,
) -> Result<()> {
    match engine_id {
        ENGINE_POSTGRES => {
            let id = xid.encode_postgres();
            // PG identifier limit is much larger than our 1+128+padding
            // hex form so length is safe; the only risk is a single-quote
            // collision, which our hex encoding eliminates.
            let sql = format!("PREPARE TRANSACTION '{}'", id);
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            let (g, b, f) = xid.encode_mysql_components();
            let sql = if b.is_empty() {
                format!("XA PREPARE '{}', '', {}", g, f)
            } else {
                format!("XA PREPARE '{}', '{}', {}", g, b, f)
            };
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // DBMS_XA.XA_PREPARE(xid). Allowed extra rc: XA_RDONLY (3)
            // — Oracle uses it to signal "this branch did no DML, I
            // already auto-completed it; no commit/rollback needed".
            // We treat that as success at this layer; the subsequent
            // commit_prepared call will see XAER_NOTA and similarly
            // accept it. Tracking the read-only branch separately
            // would require a state-machine extension; the silent
            // accept matches X/Open's documented behaviour.
            let sql = oracle_xa_block(
                &format!("DBMS_XA.XA_PREPARE({})", oracle_xid_literal(xid)),
                &[ORACLE_XA_RDONLY],
            );
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

fn apply_xa_commit(
    conn: &mut odbc_api::Connection<'static>,
    engine_id: &str,
    xid: &Xid,
    one_phase: bool,
) -> Result<()> {
    match engine_id {
        ENGINE_POSTGRES => {
            if one_phase {
                conn.execute("COMMIT", (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            } else {
                let sql = format!("COMMIT PREPARED '{}'", xid.encode_postgres());
                conn.execute(&sql, (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            }
        }
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            let (g, b, f) = xid.encode_mysql_components();
            let suffix = if one_phase { " ONE PHASE" } else { "" };
            let sql = if b.is_empty() {
                format!("XA COMMIT '{}', '', {}{}", g, f, suffix)
            } else {
                format!("XA COMMIT '{}', '{}', {}{}", g, b, f, suffix)
            };
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // DBMS_XA.XA_COMMIT(xid, onephase). For one_phase=true, we
            // also forgive XAER_PROTO (-6) which Oracle returns when
            // the branch was implicitly auto-committed (read-only DML
            // after start without prior end). Otherwise allow
            // XAER_NOTA (-4) so commit_prepared after a read-only
            // prepare is a no-op.
            let onephase_lit = if one_phase { "TRUE" } else { "FALSE" };
            let allow: &[i32] = if one_phase { &[] } else { &[ORACLE_XAER_NOTA] };
            let sql = oracle_xa_block(
                &format!(
                    "DBMS_XA.XA_COMMIT({}, {})",
                    oracle_xid_literal(xid),
                    onephase_lit,
                ),
                allow,
            );
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

/// Roll back an **Active or Idle** branch (no PREPARE issued).
/// PG and the SQL-XA family handle these identically — there is no
/// prepare-log entry to clean up.
fn apply_xa_rollback(
    conn: &mut odbc_api::Connection<'static>,
    engine_id: &str,
    xid: &Xid,
) -> Result<()> {
    match engine_id {
        ENGINE_POSTGRES => conn
            .execute("ROLLBACK", (), None)
            .map(|_| ())
            .map_err(OdbcError::from),
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            let (g, b, f) = xid.encode_mysql_components();
            let sql = if b.is_empty() {
                format!("XA ROLLBACK '{}', '', {}", g, f)
            } else {
                format!("XA ROLLBACK '{}', '{}', {}", g, b, f)
            };
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // Active/Idle rollback: XA_END(TMSUCCESS) then XA_ROLLBACK.
            // We chain both in a single PL/SQL block so a network blip
            // can't strand the branch in the Idle state.
            let xid_lit = oracle_xid_literal(xid);
            let sql = format!(
                "BEGIN DECLARE rc PLS_INTEGER; BEGIN \
                   rc := DBMS_XA.XA_END({xid}, DBMS_XA.TMSUCCESS); \
                   IF rc <> 0 THEN RAISE_APPLICATION_ERROR(-20100, 'DBMS_XA xa_end rc=' || rc); END IF; \
                   rc := DBMS_XA.XA_ROLLBACK({xid}); \
                   IF rc <> 0 THEN RAISE_APPLICATION_ERROR(-20101, 'DBMS_XA xa_rollback rc=' || rc); END IF; \
                 END; END;",
                xid = xid_lit,
            );
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

/// Roll back a **Prepared** branch (Phase 2 rollback). PostgreSQL
/// requires `ROLLBACK PREPARED '<xid>'` because the prepare log entry
/// outlives the connection. MySQL/MariaDB/DB2 use the same `XA
/// ROLLBACK` grammar regardless of state — the engine recognises the
/// xid is already prepared and does the right thing.
fn apply_xa_rollback_prepared(
    conn: &mut odbc_api::Connection<'static>,
    engine_id: &str,
    xid: &Xid,
) -> Result<()> {
    match engine_id {
        ENGINE_POSTGRES => {
            let sql = format!("ROLLBACK PREPARED '{}'", xid.encode_postgres());
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            // Same as plain xa_rollback for these engines.
            apply_xa_rollback(conn, engine_id, xid)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // Prepared rollback: only XA_ROLLBACK; XA_END was already
            // emitted by `xa_prepare`. Allow XAER_NOTA so a follow-up
            // recovery sweep on a branch that read-only-prepared
            // (Oracle auto-completed it) is a no-op.
            let sql = oracle_xa_block(
                &format!("DBMS_XA.XA_ROLLBACK({})", oracle_xid_literal(xid)),
                &[ORACLE_XAER_NOTA],
            );
            conn.execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

fn apply_xa_recover(conn: &mut odbc_api::Connection<'static>, engine_id: &str) -> Result<Vec<Xid>> {
    match engine_id {
        ENGINE_POSTGRES => {
            // Read the gid column from pg_prepared_xacts. Only XIDs
            // produced by `Xid::encode_postgres` round-trip; others
            // are skipped silently (they belong to a different
            // client).
            let mut out = Vec::new();
            let cursor = conn
                .execute("SELECT gid FROM pg_prepared_xacts", (), None)
                .map_err(OdbcError::from)?;
            if let Some(mut cursor) = cursor {
                use odbc_api::Cursor;
                while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
                    let mut buf: Vec<u8> = Vec::new();
                    if row.get_text(1, &mut buf).map_err(OdbcError::from)? {
                        if let Ok(s) = std::str::from_utf8(&buf) {
                            if let Some(xid) = Xid::decode_postgres(s) {
                                out.push(xid);
                            }
                        }
                    }
                }
            }
            Ok(out)
        }
        ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 => {
            // XA RECOVER returns: formatID, gtrid_length, bqual_length, data.
            // The `data` column carries gtrid concatenated with bqual,
            // both raw bytes. Our `apply_xa_start` always hex-encoded
            // them, so the bytes coming back here are ASCII hex.
            let mut out = Vec::new();
            let cursor = conn
                .execute("XA RECOVER", (), None)
                .map_err(OdbcError::from)?;
            if let Some(mut cursor) = cursor {
                use odbc_api::Cursor;
                while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
                    let mut format_id_buf: Vec<u8> = Vec::new();
                    let mut gtrid_len_buf: Vec<u8> = Vec::new();
                    let mut bqual_len_buf: Vec<u8> = Vec::new();
                    let mut data_buf: Vec<u8> = Vec::new();
                    let _ = row
                        .get_text(1, &mut format_id_buf)
                        .map_err(OdbcError::from)?;
                    let _ = row
                        .get_text(2, &mut gtrid_len_buf)
                        .map_err(OdbcError::from)?;
                    let _ = row
                        .get_text(3, &mut bqual_len_buf)
                        .map_err(OdbcError::from)?;
                    let _ = row.get_text(4, &mut data_buf).map_err(OdbcError::from)?;
                    let format_id: i32 = parse_ascii_int(&format_id_buf).unwrap_or(0);
                    let gtrid_len: usize = parse_ascii_int::<usize>(&gtrid_len_buf).unwrap_or(0);
                    let bqual_len: usize = parse_ascii_int::<usize>(&bqual_len_buf).unwrap_or(0);
                    if data_buf.len() < gtrid_len + bqual_len {
                        continue;
                    }
                    // Our encoding was hex strings; the engine returns
                    // them as ASCII data. Each component arrives at
                    // 2× original length because we hex-encoded.
                    let g_hex = std::str::from_utf8(&data_buf[..gtrid_len]).ok();
                    let b_hex =
                        std::str::from_utf8(&data_buf[gtrid_len..gtrid_len + bqual_len]).ok();
                    if let (Some(g), Some(b)) = (g_hex, b_hex) {
                        if let Some(xid) = Xid::decode_mysql_components(g, b, format_id) {
                            out.push(xid);
                        }
                    }
                }
            }
            Ok(out)
        }
        ENGINE_SQLSERVER => Err(unsupported_sqlserver()),
        ENGINE_ORACLE => {
            // Oracle exposes prepared XIDs via DBA_PENDING_TRANSACTIONS
            // (FORMATID NUMBER, GLOBALID RAW(64), BRANCHID RAW(64)).
            // We RAWTOHEX both binary columns so the ODBC driver
            // returns ASCII (round-trips with our HEXTORAW literals on
            // start). XIDs we can't decode (different application's
            // format) are skipped silently.
            let mut out = Vec::new();
            let cursor = conn
                .execute(
                    "SELECT FORMATID, RAWTOHEX(GLOBALID), RAWTOHEX(BRANCHID) \
                     FROM DBA_PENDING_TRANSACTIONS",
                    (),
                    None,
                )
                .map_err(OdbcError::from)?;
            if let Some(mut cursor) = cursor {
                use odbc_api::Cursor;
                while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
                    let mut format_id_buf: Vec<u8> = Vec::new();
                    let mut globalid_buf: Vec<u8> = Vec::new();
                    let mut branchid_buf: Vec<u8> = Vec::new();
                    let _ = row
                        .get_text(1, &mut format_id_buf)
                        .map_err(OdbcError::from)?;
                    let _ = row
                        .get_text(2, &mut globalid_buf)
                        .map_err(OdbcError::from)?;
                    let _ = row
                        .get_text(3, &mut branchid_buf)
                        .map_err(OdbcError::from)?;
                    let format_id: i32 = parse_ascii_int(&format_id_buf).unwrap_or(0);
                    let globalid_hex = std::str::from_utf8(&globalid_buf).unwrap_or("");
                    let branchid_hex = std::str::from_utf8(&branchid_buf).unwrap_or("");
                    if let Some(xid) =
                        Xid::decode_oracle_components(format_id, globalid_hex, branchid_hex)
                    {
                        out.push(xid);
                    }
                }
            }
            Ok(out)
        }
        _ => Err(unsupported_other(engine_id)),
    }
}

fn parse_ascii_int<T: std::str::FromStr>(bytes: &[u8]) -> Option<T> {
    std::str::from_utf8(bytes).ok()?.trim().parse::<T>().ok()
}

fn unsupported_sqlserver() -> OdbcError {
    // The MSDTC integration ships in `engine::xa_dtc` as Phase 1
    // (Sprint 4.3b): the COM ceremony is implemented but **wiring
    // into this `apply_xa_*` matrix** (translating XaTransaction
    // lifecycle calls to ITransaction::Commit/Abort and enlisting
    // the ODBC connection via `SQL_ATTR_ENLIST_IN_DTC`) is Phase 2.
    // The error wording reflects whichever phase the build is in.
    if cfg!(all(target_os = "windows", feature = "xa-dtc")) {
        OdbcError::UnsupportedFeature(
            "XA / 2PC on SQL Server: the `xa-dtc` feature ships the \
             MSDTC COM scaffolding (engine::xa_dtc) but Phase 2 wiring \
             into the apply_xa_* matrix is pending. Track \
             FUTURE_IMPLEMENTATIONS.md §4.3b for the integration TODO."
                .to_string(),
        )
    } else {
        OdbcError::UnsupportedFeature(
            "XA / 2PC on SQL Server requires MSDTC enlistment via Windows \
             COM (SQLSetConnectAttr(SQL_ATTR_ENLIST_IN_DTC, ITransaction*)). \
             Build with `--features xa-dtc` on a Windows host with MSDTC \
             enabled to activate the integration — see FUTURE_IMPLEMENTATIONS.md \
             §4.3b for the full prerequisites."
                .to_string(),
        )
    }
}

fn unsupported_other(engine_id: &str) -> OdbcError {
    OdbcError::UnsupportedFeature(format!(
        "XA / 2PC is not supported on engine {:?}. Supported engines: \
         postgres, mysql, mariadb, db2, oracle (via DBMS_XA). SQL Server \
         requires MSDTC enlistment (xa-dtc feature, Phase 2 pending).",
        engine_id,
    ))
}

#[cfg(any(test, feature = "test-helpers"))]
impl Xid {
    /// Test-only constructor that bypasses validation. Useful when a
    /// test wants to construct a known-bad XID (e.g. to feed `decode_*`).
    /// Hidden from rustdoc.
    #[doc(hidden)]
    pub fn for_test(format_id: i32, gtrid: Vec<u8>, bqual: Vec<u8>) -> Self {
        Self {
            format_id,
            gtrid,
            bqual,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::core::ENGINE_SQLITE;

    fn sample_xid() -> Xid {
        Xid::new(0x1B, b"global-tx-1".to_vec(), b"branch-A".to_vec()).unwrap()
    }

    // -----------------------------------------------------------------
    // Xid validation
    // -----------------------------------------------------------------

    #[test]
    fn xid_new_rejects_empty_gtrid() {
        let r = Xid::new(0, vec![], b"branch".to_vec());
        match r {
            Err(OdbcError::ValidationError(msg)) => {
                assert!(msg.contains("gtrid must be non-empty"));
            }
            _ => panic!("expected ValidationError, got {r:?}"),
        }
    }

    #[test]
    fn xid_new_rejects_oversize_gtrid() {
        let r = Xid::new(0, vec![b'x'; 65], vec![]);
        match r {
            Err(OdbcError::ValidationError(msg)) => {
                assert!(msg.contains("gtrid is 65 bytes"));
            }
            _ => panic!("expected ValidationError, got {r:?}"),
        }
    }

    #[test]
    fn xid_new_rejects_oversize_bqual() {
        let r = Xid::new(0, b"g".to_vec(), vec![b'x'; 65]);
        match r {
            Err(OdbcError::ValidationError(msg)) => {
                assert!(msg.contains("bqual is 65 bytes"));
            }
            _ => panic!("expected ValidationError, got {r:?}"),
        }
    }

    #[test]
    fn xid_new_accepts_max_size_components() {
        let r = Xid::new(0, vec![b'g'; 64], vec![b'b'; 64]);
        assert!(r.is_ok(), "64+64 must be accepted; got {r:?}");
    }

    #[test]
    fn xid_new_accepts_empty_bqual() {
        // Common in single-branch transactions.
        let r = Xid::new(0, b"g".to_vec(), vec![]);
        assert!(r.is_ok());
        assert!(r.unwrap().bqual().is_empty());
    }

    // -----------------------------------------------------------------
    // PostgreSQL encoding round-trip
    // -----------------------------------------------------------------

    #[test]
    fn xid_postgres_round_trip() {
        let original = sample_xid();
        let encoded = original.encode_postgres();
        let decoded = Xid::decode_postgres(&encoded).expect("must round-trip");
        assert_eq!(decoded, original);
    }

    #[test]
    fn xid_postgres_encoding_is_ascii_hex() {
        let xid = sample_xid();
        let encoded = xid.encode_postgres();
        // Expected format: "27_<hex>_<hex>" (0x1B = 27 decimal)
        assert!(encoded.starts_with("27_"), "got {encoded}");
        // Body must be 0-9 a-f _ only — safe for SQL identifiers
        assert!(
            encoded
                .chars()
                .all(|c| c.is_ascii_hexdigit() || c == '_' || c == '-'),
            "encoded form must be ASCII-clean; got {encoded}",
        );
    }

    #[test]
    fn xid_postgres_decode_rejects_garbage() {
        assert!(Xid::decode_postgres("").is_none());
        assert!(Xid::decode_postgres("foo").is_none());
        assert!(Xid::decode_postgres("0_").is_none());
        // Non-hex gtrid:
        assert!(Xid::decode_postgres("0_xyzz_").is_none());
    }

    #[test]
    fn xid_postgres_round_trip_with_empty_bqual() {
        let xid = Xid::new(0, b"g".to_vec(), vec![]).unwrap();
        let encoded = xid.encode_postgres();
        // Format: "0_67_" (67 = 'g' in hex)
        assert_eq!(encoded, "0_67_");
        let decoded = Xid::decode_postgres(&encoded).expect("must round-trip");
        assert_eq!(decoded, xid);
    }

    #[test]
    fn xid_postgres_round_trip_with_binary_payload() {
        let xid = Xid::new(7, vec![0x00, 0xFF, 0x10, 0x20], vec![0xAB]).unwrap();
        let encoded = xid.encode_postgres();
        let decoded = Xid::decode_postgres(&encoded).expect("must round-trip");
        assert_eq!(decoded, xid);
    }

    // -----------------------------------------------------------------
    // MySQL/MariaDB/DB2 component encoding
    // -----------------------------------------------------------------

    #[test]
    fn xid_mysql_components_round_trip() {
        let original = sample_xid();
        let (g, b, f) = original.encode_mysql_components();
        let decoded = Xid::decode_mysql_components(&g, &b, f).expect("must round-trip");
        assert_eq!(decoded, original);
    }

    #[test]
    fn xid_mysql_components_format() {
        let xid = sample_xid();
        let (g, b, f) = xid.encode_mysql_components();
        assert_eq!(f, 0x1B);
        // Each component must be 2× original length (hex encoding)
        assert_eq!(g.len(), 11 * 2, "gtrid hex length");
        assert_eq!(b.len(), 8 * 2, "bqual hex length");
        // Must be lowercase hex
        assert!(g
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    }

    #[test]
    fn xid_hex_encode_decode_round_trip() {
        for data in &[
            vec![],
            vec![0x00],
            vec![0xFF],
            vec![0x00, 0x01, 0x02, 0xFE, 0xFF],
            (0..=255_u8).collect::<Vec<u8>>(),
        ] {
            let encoded = hex_encode(data);
            let decoded = hex_decode(&encoded).expect("round-trip");
            assert_eq!(&decoded, data);
        }
    }

    #[test]
    fn xid_hex_decode_rejects_odd_length() {
        assert!(hex_decode("a").is_none());
        assert!(hex_decode("abc").is_none());
    }

    #[test]
    fn xid_hex_decode_rejects_non_hex() {
        assert!(hex_decode("xy").is_none());
        assert!(hex_decode("ab__").is_none());
    }

    // -----------------------------------------------------------------
    // SQL emitter shape (engines that error out cleanly)
    // -----------------------------------------------------------------

    #[test]
    fn unsupported_sqlserver_message_points_at_dtc() {
        let err = unsupported_sqlserver();
        let s = err.to_string();
        // MSDTC must be mentioned in BOTH variants (no-feature + feature
        // enabled). The cfg!() switch picks the right body; the test
        // pins the universal substring so a refactor can't accidentally
        // drop the actionable hint.
        assert!(s.contains("MSDTC"));
        assert!(s.contains("FUTURE_IMPLEMENTATIONS"));
    }

    #[test]
    fn unsupported_other_lists_supported_engines() {
        let err = unsupported_other(ENGINE_SQLITE);
        let s = err.to_string();
        assert!(s.contains("sqlite"));
        assert!(s.contains("postgres"));
        assert!(s.contains("mysql"));
        assert!(s.contains("mariadb"));
        assert!(s.contains("db2"));
        assert!(s.contains("oracle"));
    }

    // -----------------------------------------------------------------
    // Oracle DBMS_XA encoding round-trips (unit-only — no live DB)
    // -----------------------------------------------------------------

    #[test]
    fn xid_oracle_components_round_trip() {
        let original = Xid::new(7, vec![0xDE, 0xAD, 0xBE, 0xEF], vec![0xCA, 0xFE]).unwrap();
        let (fmt, g, b) = original.encode_oracle_components();
        assert_eq!(fmt, 7);
        assert_eq!(g, "DEADBEEF");
        assert_eq!(b, "CAFE");
        let decoded = Xid::decode_oracle_components(fmt, &g, &b).expect("must round-trip");
        assert_eq!(decoded, original);
    }

    #[test]
    fn xid_oracle_decode_accepts_lowercase_hex() {
        // Some recovery sweeps may surface lowercase hex; we accept
        // both so the helper doesn't trip over a future driver
        // change.
        let xid = Xid::decode_oracle_components(0, "abcd", "ef").expect("lowercase ok");
        assert_eq!(xid.gtrid(), &[0xAB, 0xCD][..]);
        assert_eq!(xid.bqual(), &[0xEF][..]);
    }

    #[test]
    fn oracle_xid_literal_emits_dbms_xa_xid_constructor() {
        let xid = Xid::new(0x1B, b"global".to_vec(), b"branch".to_vec()).unwrap();
        let lit = oracle_xid_literal(&xid);
        // 'global' = 676C6F62616C ; 'branch' = 6272616E6368.
        // Verify uppercase hex (Oracle's RAWTOHEX convention) and the
        // exact constructor name we tested live in the sandbox.
        assert_eq!(
            lit,
            "SYS.DBMS_XA_XID(27, HEXTORAW('676C6F62616C'), HEXTORAW('6272616E6368'))"
        );
    }

    #[test]
    fn oracle_xa_block_wraps_call_with_rc_check() {
        let sql = oracle_xa_block("DBMS_XA.XA_PREPARE(x)", &[3]);
        assert!(sql.contains("DBMS_XA.XA_PREPARE(x)"));
        assert!(sql.contains("rc <> 0"));
        assert!(sql.contains("rc <> 3"));
        assert!(sql.contains("RAISE_APPLICATION_ERROR(-20100"));
    }

    // -----------------------------------------------------------------
    // PreparedXa state machine guards
    // -----------------------------------------------------------------

    #[test]
    fn prepared_xa_commit_rejects_wrong_state() {
        let handles =
            std::sync::Arc::new(std::sync::Mutex::new(crate::handles::HandleManager::new()));
        let xa = PreparedXa {
            handles,
            conn_id: u32::MAX,
            xid: sample_xid(),
            engine_id: ENGINE_POSTGRES.to_string(),
            state: Arc::new(Mutex::new(XaState::Active)),
        };
        let r = xa.commit();
        match r {
            Err(OdbcError::ValidationError(msg)) => {
                assert!(msg.contains("expected state Prepared, got Active"));
            }
            _ => panic!("expected ValidationError, got {r:?}"),
        }
    }
}

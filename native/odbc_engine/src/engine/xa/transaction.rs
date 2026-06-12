#[cfg(all(target_os = "windows", feature = "xa-dtc"))]
use crate::engine::core::ENGINE_SQLSERVER;
use crate::error::{OdbcError, Result};
use crate::handles::SharedHandleManager;
use std::sync::{Arc, Mutex};

use super::apply::{
    apply_xa_commit, apply_xa_end, apply_xa_prepare, apply_xa_recover, apply_xa_rollback,
    apply_xa_rollback_prepared, apply_xa_start, detect_engine_id,
};
use super::mssql::mssql_mdtc_unenlist;
use super::xid::Xid;

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
    /// Set when `engine_id` is SQL Server, built with `xa-dtc` on Windows: MSDTC branch.
    #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
    dtc_branch: Option<Box<crate::engine::xa_dtc::DtcXaBranch>>,
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
    #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
    dtc_branch: Option<Box<crate::engine::xa_dtc::DtcXaBranch>>,
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

        #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
        {
            if engine_id == ENGINE_SQLSERVER {
                use crate::engine::xa_dtc::{begin_dtc_branch, enlist_connection_in_dtc};
                let branch = begin_dtc_branch(&xid)?;
                enlist_connection_in_dtc(conn.connection_mut(), branch.transaction())?;
                return Ok(Self {
                    handles,
                    conn_id,
                    xid,
                    engine_id,
                    state: Arc::new(Mutex::new(XaState::Active)),
                    dtc_branch: Some(Box::new(branch)),
                });
            }
        }

        apply_xa_start(conn.connection_mut(), &engine_id, &xid)?;

        Ok(Self {
            handles,
            conn_id,
            xid,
            engine_id,
            state: Arc::new(Mutex::new(XaState::Active)),
            #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
            dtc_branch: None,
        })
    }

    fn is_mssql_mdtc(&self) -> bool {
        #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
        {
            self.engine_id == ENGINE_SQLSERVER && self.dtc_branch.is_some()
        }
        #[cfg(not(all(target_os = "windows", feature = "xa-dtc")))]
        {
            false
        }
    }

    pub fn xid(&self) -> &Xid {
        &self.xid
    }

    pub fn state(&self) -> XaState {
        self.state.lock().map(|s| *s).unwrap_or(XaState::Failed)
    }

    fn set_state(&self, state: XaState) -> Result<()> {
        *self
            .state
            .lock()
            .map_err(|_| OdbcError::InternalError("XA state lock poisoned".to_string()))? = state;
        Ok(())
    }

    /// `xa_end`: detach the branch from the connection. After this
    /// the connection can be reused for other work or for
    /// `xa_prepare` on this branch.
    pub fn end(self) -> Result<PreparingXa> {
        self.assert_state(XaState::Active, "end")?;
        if self.is_mssql_mdtc() {
            self.run_on_conn(|c, _e, _x| mssql_mdtc_unenlist(c))?;
        } else {
            self.run_on_conn(apply_xa_end)?;
        }
        self.set_state(XaState::Idle)?;
        Ok(PreparingXa { inner: self })
    }

    /// 1RM optimisation: fuse `prepare → commit_prepared` for the
    /// case where this RM is the sole participant. Avoids the disk
    /// write of the prepare log. **Only safe when no other RM has
    /// enlisted in the same global transaction.**
    #[allow(unused_mut)] // `dtc_branch.take()` only with `xa-dtc` on Windows
    pub fn commit_one_phase(mut self) -> Result<()> {
        self.assert_state(XaState::Active, "commit_one_phase")?;
        if self.is_mssql_mdtc() {
            // Single-RM: unenlist then commit the MSDTC unit of work.
            self.run_on_conn(|c, _e, _x| mssql_mdtc_unenlist(c))?;
            #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
            {
                if let Some(b) = self.dtc_branch.take() {
                    b.commit()?;
                }
            }
            self.set_state(XaState::Committed)?;
            let _ = self.try_restore_autocommit();
            return Ok(());
        }
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
                self.set_state(XaState::Committed)?;
                Ok(())
            }
            (Err(e), _) => {
                self.set_state(XaState::Failed)?;
                Err(e)
            }
        }
    }

    /// Roll back an Active branch (no PREPARE was issued). Equivalent
    /// to `xa_end` + `xa_rollback`. After this call the branch is
    /// gone — there is no recovery path because no prepare-log entry
    /// exists.
    #[allow(unused_mut)] // `dtc_branch.take()` only with `xa-dtc` on Windows
    pub fn rollback(mut self) -> Result<()> {
        self.assert_state(XaState::Active, "rollback")?;
        if self.is_mssql_mdtc() {
            let _ = self.run_on_conn(|c, _e, _x| mssql_mdtc_unenlist(c));
            #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
            {
                if let Some(b) = self.dtc_branch.take() {
                    let _ = b.abort();
                }
            }
            let _ = self.try_restore_autocommit();
            self.set_state(XaState::RolledBack)?;
            return Ok(());
        }
        let _ = self.run_on_conn(apply_xa_end);
        let r = self.run_on_conn(apply_xa_rollback);
        let _ = self.try_restore_autocommit();
        match r {
            Ok(()) => {
                self.set_state(XaState::RolledBack)?;
                Ok(())
            }
            Err(e) => {
                self.set_state(XaState::Failed)?;
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
            if self.is_mssql_mdtc() {
                let _ = self.run_on_conn(|c, _e, _x| mssql_mdtc_unenlist(c));
                #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
                {
                    if let Some(b) = self.dtc_branch.take() {
                        let _ = b.abort();
                    }
                }
            } else {
                // Best-effort rollback. We can't propagate errors from Drop;
                // the warn! above plus any structured error in the engine
                // logs is the only signal.
                let _ = self.run_on_conn(|c, e, x| {
                    let _ = apply_xa_end(c, e, x);
                    apply_xa_rollback(c, e, x)
                });
            }
            let _ = self.try_restore_autocommit();
        }
    }
}

fn set_xa_state(state: &Arc<Mutex<XaState>>, value: XaState) -> Result<()> {
    *state
        .lock()
        .map_err(|_| OdbcError::InternalError("XA state lock poisoned".to_string()))? = value;
    Ok(())
}

impl PreparingXa {
    /// `xa_prepare`: Phase 1 of 2PC. On success the branch becomes
    /// **heuristically committable** — its outcome survives a process
    /// crash and can be resolved later via [`recover_prepared_xids`].
    pub fn prepare(self) -> Result<PreparedXa> {
        #[allow(unused_mut)] // `dtc_branch.take()` only with `xa-dtc` on Windows
        let mut inner = self.inner;
        inner.assert_state(XaState::Idle, "prepare")?;
        if inner.is_mssql_mdtc() {
            // MSDTC: no SQL PREPARE — branch is already coordinated by DTC.
            inner.set_state(XaState::Prepared)?;
            let _ = inner.try_restore_autocommit();
            let handles = inner.handles.clone();
            let conn_id = inner.conn_id;
            let xid = inner.xid.clone();
            let engine_id = inner.engine_id.clone();
            let state = inner.state.clone();
            #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
            let dtc = inner.dtc_branch.take();
            drop(inner);
            return Ok(PreparedXa {
                handles,
                conn_id,
                xid,
                engine_id,
                state,
                #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
                dtc_branch: dtc,
            });
        }
        let r = inner.run_on_conn(apply_xa_prepare);
        match r {
            Ok(()) => {
                inner.set_state(XaState::Prepared)?;
                let _ = inner.try_restore_autocommit();
                Ok(PreparedXa {
                    handles: inner.handles.clone(),
                    conn_id: inner.conn_id,
                    xid: inner.xid.clone(),
                    engine_id: inner.engine_id.clone(),
                    state: inner.state.clone(),
                    #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
                    dtc_branch: None,
                })
            }
            Err(e) => {
                inner.set_state(XaState::Failed)?;
                let _ = inner.try_restore_autocommit();
                Err(e)
            }
        }
    }

    /// Roll back without preparing — equivalent to
    /// [`XaTransaction::rollback`] but valid in the `Idle` state too.
    pub fn rollback(self) -> Result<()> {
        #[allow(unused_mut)] // `dtc_branch.take()` only with `xa-dtc` on Windows
        let mut inner = self.inner;
        inner.assert_state(XaState::Idle, "rollback")?;
        if inner.is_mssql_mdtc() {
            let _ = inner.run_on_conn(|c, _e, _x| mssql_mdtc_unenlist(c));
            #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
            {
                if let Some(b) = inner.dtc_branch.take() {
                    let _ = b.abort();
                }
            }
            let _ = inner.try_restore_autocommit();
            inner.set_state(XaState::RolledBack)?;
            return Ok(());
        }
        let r = inner.run_on_conn(apply_xa_rollback);
        let _ = inner.try_restore_autocommit();
        match r {
            Ok(()) => {
                inner.set_state(XaState::RolledBack)?;
                Ok(())
            }
            Err(e) => {
                inner.set_state(XaState::Failed)?;
                Err(e)
            }
        }
    }
}

impl PreparedXa {
    pub fn xid(&self) -> &Xid {
        &self.xid
    }

    fn set_state(&self, state: XaState) -> Result<()> {
        set_xa_state(&self.state, state)
    }

    /// `xa_commit` (Phase 2): finalise the prepared branch. Returns
    /// success only when the engine confirmed the commit hit stable
    /// storage.
    pub fn commit(self) -> Result<()> {
        self.assert_state(XaState::Prepared, "commit")?;
        #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
        {
            let state = self.state.clone();
            if let Some(b) = self.dtc_branch {
                let r = b.commit();
                match r {
                    Ok(()) => {
                        set_xa_state(&state, XaState::Committed)?;
                        return Ok(());
                    }
                    Err(e) => {
                        set_xa_state(&state, XaState::Failed)?;
                        return Err(e);
                    }
                }
            }
        }
        let r = self.run_on_conn(|c, e, x| apply_xa_commit(c, e, x, false));
        match r {
            Ok(()) => {
                self.set_state(XaState::Committed)?;
                Ok(())
            }
            Err(e) => {
                self.set_state(XaState::Failed)?;
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
        #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
        {
            let state = self.state.clone();
            if let Some(b) = self.dtc_branch {
                let r = b.abort();
                match r {
                    Ok(()) => {
                        set_xa_state(&state, XaState::RolledBack)?;
                        return Ok(());
                    }
                    Err(e) => {
                        set_xa_state(&state, XaState::Failed)?;
                        return Err(e);
                    }
                }
            }
        }
        let r = self.run_on_conn(apply_xa_rollback_prepared);
        match r {
            Ok(()) => {
                self.set_state(XaState::RolledBack)?;
                Ok(())
            }
            Err(e) => {
                self.set_state(XaState::Failed)?;
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
        #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
        dtc_branch: None,
    })
}

#[cfg(test)]
impl XaTransaction {
    /// Unit-test handle with no live connection; state guards run before ODBC.
    pub(crate) fn from_test_state(state: XaState, engine_id: &str, xid: Xid) -> Self {
        Self {
            handles: Arc::new(Mutex::new(crate::handles::HandleManager::new())),
            conn_id: u32::MAX,
            xid,
            engine_id: engine_id.to_string(),
            state: Arc::new(Mutex::new(state)),
            #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
            dtc_branch: None,
        }
    }
}

#[cfg(test)]
impl PreparingXa {
    pub(crate) fn from_test_transaction(inner: XaTransaction) -> Self {
        Self { inner }
    }
}

#[cfg(test)]
impl PreparedXa {
    pub(crate) fn from_test_state(state: XaState, engine_id: &str, xid: Xid) -> Self {
        Self {
            handles: Arc::new(Mutex::new(crate::handles::HandleManager::new())),
            conn_id: u32::MAX,
            xid,
            engine_id: engine_id.to_string(),
            state: Arc::new(Mutex::new(state)),
            #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
            dtc_branch: None,
        }
    }
}

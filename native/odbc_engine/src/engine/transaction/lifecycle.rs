//! Transaction lifecycle: begin, commit, rollback, scoped execution, and drop cleanup.

use std::sync::{Arc, Mutex};

use crate::error::{OdbcError, Result};
use crate::handles::{HandleManager, SharedHandleManager};
use crate::pool::SharedPooledConnection;

use super::dialect_sql::{apply_access_mode, apply_isolation, apply_lock_timeout};
use super::{
    IsolationLevel, LockTimeout, SavepointDialect, Transaction, TransactionAccessMode,
    TransactionConnection, TransactionState,
};

impl Transaction {
    pub fn begin(
        handles: SharedHandleManager,
        conn_id: u32,
        isolation_level: IsolationLevel,
    ) -> Result<Self> {
        Self::begin_with_dialect(handles, conn_id, isolation_level, SavepointDialect::Auto)
    }

    pub fn begin_with_dialect(
        handles: SharedHandleManager,
        conn_id: u32,
        isolation_level: IsolationLevel,
        savepoint_dialect: SavepointDialect,
    ) -> Result<Self> {
        Self::begin_with_access_mode(
            handles,
            conn_id,
            isolation_level,
            savepoint_dialect,
            TransactionAccessMode::ReadWrite,
        )
    }

    /// Begin a transaction with full control over isolation, savepoint
    /// dialect and access mode (`READ ONLY` / `READ WRITE`).
    ///
    /// Sprint 4.1 — see `CHANGELOG.md` `[3.4.0]` and
    /// the [`TransactionAccessMode`] doc for the engine matrix.
    pub fn begin_with_access_mode(
        handles: SharedHandleManager,
        conn_id: u32,
        isolation_level: IsolationLevel,
        savepoint_dialect: SavepointDialect,
        access_mode: TransactionAccessMode,
    ) -> Result<Self> {
        Self::begin_with_lock_timeout(
            handles,
            conn_id,
            isolation_level,
            savepoint_dialect,
            access_mode,
            LockTimeout::engine_default(),
        )
    }

    /// Begin a transaction with full control over isolation, savepoint
    /// dialect, access mode AND per-transaction lock timeout.
    ///
    /// Sprint 4.2 — see `CHANGELOG.md` `[3.4.0]` and
    /// the [`LockTimeout`] doc for the engine matrix. Pass
    /// [`LockTimeout::engine_default`] (the `Default` impl) to skip
    /// the override and behave exactly like
    /// [`begin_with_access_mode`].
    pub fn begin_with_lock_timeout(
        handles: SharedHandleManager,
        conn_id: u32,
        isolation_level: IsolationLevel,
        savepoint_dialect: SavepointDialect,
        access_mode: TransactionAccessMode,
        lock_timeout: LockTimeout,
    ) -> Result<Self> {
        Self::begin_with_connection(
            TransactionConnection::Regular(handles),
            conn_id,
            isolation_level,
            savepoint_dialect,
            access_mode,
            lock_timeout,
        )
    }

    pub(crate) fn begin_on_pooled_with_lock_timeout(
        pooled: SharedPooledConnection,
        conn_id: u32,
        isolation_level: IsolationLevel,
        savepoint_dialect: SavepointDialect,
        access_mode: TransactionAccessMode,
        lock_timeout: LockTimeout,
    ) -> Result<Self> {
        Self::begin_with_connection(
            TransactionConnection::Pooled(pooled),
            conn_id,
            isolation_level,
            savepoint_dialect,
            access_mode,
            lock_timeout,
        )
    }

    fn begin_with_connection(
        connection: TransactionConnection,
        conn_id: u32,
        isolation_level: IsolationLevel,
        savepoint_dialect: SavepointDialect,
        access_mode: TransactionAccessMode,
        lock_timeout: LockTimeout,
    ) -> Result<Self> {
        let (engine_id, resolved_dialect) =
            connection.detect_engine_and_dialect(conn_id, savepoint_dialect);
        let state = Arc::new(Mutex::new(TransactionState::Active));

        connection.with_connection_mut(conn_id, "begin transaction", |conn| {
            // Apply isolation level using a dialect-aware strategy. Must run BEFORE
            // `set_autocommit(false)` because some engines (notably SQL Server)
            // refuse `SET TRANSACTION ISOLATION LEVEL` inside an open transaction.
            apply_isolation(conn, &engine_id, isolation_level)?;

            // Access mode must follow isolation. Oracle is special-cased inside
            // `apply_access_mode` because `SET TRANSACTION READ ONLY` overrides
            // the previous isolation choice on that engine.
            apply_access_mode(conn, &engine_id, access_mode)?;

            // Lock timeout is engine-aware too. PostgreSQL uses `SET LOCAL`
            // (so it auto-resets on commit/rollback); other engines apply
            // session-wide. The override is best-effort: failure here would
            // prevent the transaction from starting, which is too coarse,
            // so we surface the engine error verbatim and let the caller
            // decide.
            apply_lock_timeout(conn, &engine_id, lock_timeout)?;

            conn.set_autocommit(false).map_err(OdbcError::from)
        })?;

        Ok(Self {
            connection,
            conn_id,
            state,
            isolation_level,
            savepoint_dialect: resolved_dialect,
            access_mode,
            lock_timeout,
        })
    }

    pub fn commit(self) -> Result<()> {
        let mut s = self.state.lock().map_err(|_| {
            OdbcError::InternalError("Failed to lock transaction state".to_string())
        })?;
        if *s != TransactionState::Active {
            return Err(OdbcError::ValidationError(format!(
                "Cannot commit: transaction state is {:?}",
                *s
            )));
        }

        let (commit_result, autocommit_result) =
            self.connection
                .with_connection_mut(self.conn_id, "commit transaction", |conn| {
                    Ok((
                        conn.commit().map_err(OdbcError::from),
                        conn.set_autocommit(true),
                    ))
                })?;
        // ALWAYS try to restore autocommit, regardless of commit outcome (B7 fix).
        // If commit failed the driver may already have rolled back and reset
        // autocommit; the call is a best-effort safety net so the connection
        // is never returned to the caller / pool stuck in autocommit=off.
        if let Err(e) = autocommit_result {
            log::error!(
                "Transaction::commit: failed to restore autocommit on conn_id {}: {e}",
                self.conn_id
            );
        }

        match commit_result {
            Ok(()) => {
                *s = TransactionState::Committed;
                Ok(())
            }
            Err(e) => {
                // Commit failed → driver semantics say the transaction was
                // rolled back (or is in an undefined state, which we model as
                // RolledBack to allow reuse). Surface the original error.
                *s = TransactionState::RolledBack;
                Err(e)
            }
        }
    }

    pub fn rollback(self) -> Result<()> {
        let mut s = self.state.lock().map_err(|_| {
            OdbcError::InternalError("Failed to lock transaction state".to_string())
        })?;
        if *s != TransactionState::Active {
            return Err(OdbcError::ValidationError(format!(
                "Cannot rollback: transaction state is {:?}",
                *s
            )));
        }

        let (rollback_result, autocommit_result) =
            self.connection
                .with_connection_mut(self.conn_id, "rollback transaction", |conn| {
                    Ok((
                        conn.rollback().map_err(OdbcError::from),
                        conn.set_autocommit(true),
                    ))
                })?;
        // ALWAYS restore autocommit (B7 fix), same rationale as `commit`.
        if let Err(e) = autocommit_result {
            log::error!(
                "Transaction::rollback: failed to restore autocommit on conn_id {}: {e}",
                self.conn_id
            );
        }

        // Whether the engine accepted the rollback or not, this Transaction
        // value is consumed and can no longer be used.
        *s = TransactionState::RolledBack;
        rollback_result
    }

    pub fn execute<F, T>(
        handles: SharedHandleManager,
        conn_id: u32,
        isolation: IsolationLevel,
        f: F,
    ) -> Result<T>
    where
        F: FnOnce(&Transaction) -> Result<T>,
    {
        Self::execute_with_dialect(handles, conn_id, isolation, SavepointDialect::Auto, f)
    }

    pub fn execute_with_dialect<F, T>(
        handles: SharedHandleManager,
        conn_id: u32,
        isolation: IsolationLevel,
        savepoint_dialect: SavepointDialect,
        f: F,
    ) -> Result<T>
    where
        F: FnOnce(&Transaction) -> Result<T>,
    {
        Self::execute_with_access_mode(
            handles,
            conn_id,
            isolation,
            savepoint_dialect,
            TransactionAccessMode::ReadWrite,
            f,
        )
    }

    /// Run `f` inside a fully-qualified transaction (isolation + savepoint
    /// dialect + access mode) with automatic commit on success and
    /// rollback on error.
    pub fn execute_with_access_mode<F, T>(
        handles: SharedHandleManager,
        conn_id: u32,
        isolation: IsolationLevel,
        savepoint_dialect: SavepointDialect,
        access_mode: TransactionAccessMode,
        f: F,
    ) -> Result<T>
    where
        F: FnOnce(&Transaction) -> Result<T>,
    {
        Self::execute_with_lock_timeout(
            handles,
            conn_id,
            isolation,
            savepoint_dialect,
            access_mode,
            LockTimeout::engine_default(),
            f,
        )
    }

    /// Run `f` inside a fully-qualified transaction (isolation + savepoint
    /// dialect + access mode + lock timeout) with automatic commit on
    /// success and rollback on error.
    pub fn execute_with_lock_timeout<F, T>(
        handles: SharedHandleManager,
        conn_id: u32,
        isolation: IsolationLevel,
        savepoint_dialect: SavepointDialect,
        access_mode: TransactionAccessMode,
        lock_timeout: LockTimeout,
        f: F,
    ) -> Result<T>
    where
        F: FnOnce(&Transaction) -> Result<T>,
    {
        let txn = Self::begin_with_lock_timeout(
            handles.clone(),
            conn_id,
            isolation,
            savepoint_dialect,
            access_mode,
            lock_timeout,
        )?;
        match f(&txn) {
            Ok(result) => {
                txn.commit()?;
                Ok(result)
            }
            Err(original) => {
                if let Err(rollback_err) = txn.rollback() {
                    log::error!(
                        "Rollback after error failed on conn_id {conn_id}: original={original}, rollback={rollback_err}"
                    );
                }
                Err(original)
            }
        }
    }

    pub fn execute_sql(&self, sql: &str) -> Result<()> {
        self.connection
            .with_connection(self.conn_id, "execute_sql", |conn| {
                conn.execute(sql, (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            })
    }

    pub fn is_active(&self) -> bool {
        self.state
            .lock()
            .map(|s| *s == TransactionState::Active)
            .unwrap_or(false)
    }

    pub fn isolation_level(&self) -> IsolationLevel {
        self.isolation_level
    }

    pub fn conn_id(&self) -> u32 {
        self.conn_id
    }

    pub fn handles(&self) -> SharedHandleManager {
        self.connection
            .handles()
            .unwrap_or_else(|| Arc::new(Mutex::new(HandleManager::new())))
    }

    pub fn savepoint_dialect(&self) -> SavepointDialect {
        self.savepoint_dialect
    }

    pub fn access_mode(&self) -> TransactionAccessMode {
        self.access_mode
    }

    pub fn lock_timeout(&self) -> LockTimeout {
        self.lock_timeout
    }
}

impl Drop for Transaction {
    fn drop(&mut self) {
        let s = self
            .state
            .lock()
            .map(|s| *s)
            .unwrap_or(TransactionState::None);
        if s != TransactionState::Active {
            return;
        }
        log::warn!(
            "Transaction on conn_id {} dropped without commit - auto-rollback",
            self.conn_id
        );
        if let Err(e) =
            self.connection
                .with_connection_mut(self.conn_id, "drop transaction", |conn| {
                    if let Err(e) = conn.rollback() {
                        log::error!(
                            "Transaction Drop: rollback failed on conn_id {}: {e}",
                            self.conn_id
                        );
                    }
                    if let Err(e) = conn.set_autocommit(true) {
                        log::error!(
                            "Transaction Drop: set_autocommit(true) failed on conn_id {}: {e}",
                            self.conn_id
                        );
                    }
                    Ok(())
                })
        {
            log::error!(
                "Transaction Drop: failed to cleanup conn_id {}: {e}",
                self.conn_id
            );
        }
    }
}

//! Transaction lifecycle: begin, commit, rollback, scoped execution, and drop cleanup.

use std::sync::{Arc, Mutex};

use crate::engine::core::ENGINE_POSTGRES;
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
        let state = Arc::new(Mutex::new(TransactionState::Active));

        // Single connection lock: resolve engine (cache / SQL_DBMS_NAME) then
        // apply isolation / access mode / lock timeout / autocommit.
        let resolved_dialect =
            connection.with_cached_mut(conn_id, "begin transaction", |cached| {
                let (engine_id, resolved_dialect) =
                    TransactionConnection::resolve_engine_and_dialect(
                        cached,
                        conn_id,
                        savepoint_dialect,
                    );

                let mut manual_started = false;
                let mut attempted_manual = false;
                let setup = (|| {
                    if engine_id == ENGINE_POSTGRES {
                        attempted_manual = true;
                        cached.connection().set_autocommit(false).map_err(OdbcError::from)?;
                        manual_started = true;
                    }
                    apply_isolation(cached.connection(), engine_id, isolation_level)?;
                    let isolation_changes_session =
                        crate::engine::session_defaults::session_isolation_reset_sql(engine_id)
                            .is_some()
                            && match engine_id {
                                crate::engine::core::ENGINE_SQLITE => {
                                    isolation_level == IsolationLevel::ReadUncommitted
                                }
                                _ => isolation_level != IsolationLevel::ReadCommitted,
                            };
                    if isolation_changes_session {
                        cached.mark_session_isolation_dirty();
                    }
                    apply_access_mode(cached.connection(), engine_id, access_mode)?;
                    let applied = apply_lock_timeout(cached.connection(), engine_id, lock_timeout)?;
                    if applied && super::dialect_sql::lock_timeout_is_session_scoped(engine_id) {
                        cached.mark_session_lock_timeout_dirty();
                    }
                    if !manual_started {
                        attempted_manual = true;
                        cached.connection().set_autocommit(false).map_err(OdbcError::from)?;
                        manual_started = true;
                    }
                    Ok(resolved_dialect)
                })();
                if let Err(original) = setup {
                    let mut cleanup_failure = None;
                    if attempted_manual && !manual_started {
                        cached.mark_unusable();
                    }
                    if manual_started {
                        if let Err(cleanup) = cached.end_transaction(false) {
                            log::error!("Transaction begin cleanup failed on conn_id {conn_id}: {cleanup}; original: {original}");
                            cleanup_failure = Some(cleanup);
                        }
                    } else {
                        if let Err(cleanup) = cached.try_restore_session_settings_if_dirty() {
                            log::error!("Transaction begin settings cleanup failed on conn_id {conn_id}: {cleanup}; original: {original}");
                            cleanup_failure = Some(cleanup);
                        }
                        // A failed pre-autocommit statement can have changed
                        // the session even when the driver returned an error.
                        cached.mark_unusable();
                    }
                    return Err(match cleanup_failure {
                        Some(cleanup) => append_begin_cleanup_failure(original, cleanup),
                        None => original,
                    });
                }
                setup
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

        *s = TransactionState::None;
        let result =
            self.connection
                .with_cached_mut(self.conn_id, "commit transaction", |cached| {
                    cached.end_transaction(true)
                });
        if result.is_ok() {
            *s = TransactionState::Committed;
        }
        result
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

        *s = TransactionState::None;
        let result =
            self.connection
                .with_cached_mut(self.conn_id, "rollback transaction", |cached| {
                    cached.end_transaction(false)
                });
        if result.is_ok() {
            *s = TransactionState::RolledBack;
        }
        result
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

fn append_begin_cleanup_failure(original: OdbcError, cleanup: OdbcError) -> OdbcError {
    match original {
        OdbcError::Structured {
            sqlstate,
            native_code,
            message,
        } => OdbcError::Structured {
            sqlstate,
            native_code,
            message: format!("{message}; begin cleanup failed: {cleanup}"),
        },
        OdbcError::OdbcApi(message) => {
            OdbcError::OdbcApi(format!("{message}; begin cleanup failed: {cleanup}"))
        }
        OdbcError::PoolError(message) => {
            OdbcError::PoolError(format!("{message}; begin cleanup failed: {cleanup}"))
        }
        other => other,
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
                .with_cached_mut(self.conn_id, "drop transaction", |cached| {
                    cached.end_transaction(false)
                })
        {
            log::error!(
                "Transaction Drop: failed to cleanup conn_id {}: {e}",
                self.conn_id
            );
        }
    }
}

#[cfg(test)]
mod cleanup_diagnostic_tests {
    use super::*;

    #[test]
    fn begin_cleanup_keeps_original_sqlstate_and_native_code() {
        let original = OdbcError::Structured {
            sqlstate: *b"40001",
            native_code: 1205,
            message: "deadlock victim".to_string(),
        };
        let result = append_begin_cleanup_failure(
            original,
            OdbcError::PoolError("reset failed".to_string()),
        );
        let OdbcError::Structured {
            sqlstate,
            native_code,
            message,
        } = result
        else {
            panic!("original structured diagnostic must survive");
        };
        assert_eq!(sqlstate, *b"40001");
        assert_eq!(native_code, 1205);
        assert!(message.contains("deadlock victim"));
        assert!(message.contains("reset failed"));
    }
}

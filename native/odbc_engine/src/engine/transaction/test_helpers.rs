use std::sync::{Arc, Mutex};

use crate::handles::{HandleManager, SharedHandleManager};

use super::{
    IsolationLevel, LockTimeout, SavepointDialect, Transaction, TransactionAccessMode,
    TransactionConnection, TransactionState,
};

impl Transaction {
    /// Test-only constructor. Builds a `Transaction` value without touching the
    /// driver — useful for unit / regression tests that exercise validation
    /// logic (identifier quoting, state-machine guards) in isolation.
    /// Hidden from rustdoc; not part of the public API surface.
    #[doc(hidden)]
    pub fn for_test(
        handles: SharedHandleManager,
        conn_id: u32,
        state: TransactionState,
        isolation_level: IsolationLevel,
    ) -> Self {
        Self::assemble_for_test(
            TransactionConnection::Regular(handles),
            conn_id,
            state,
            isolation_level,
            SavepointDialect::Sql92,
            TransactionAccessMode::ReadWrite,
            LockTimeout::engine_default(),
        )
    }

    /// Test-only constructor that lets the caller pin a specific
    /// `SavepointDialect`. See [`for_test`] for caveats.
    #[doc(hidden)]
    pub fn for_test_with_dialect(
        handles: SharedHandleManager,
        conn_id: u32,
        state: TransactionState,
        isolation_level: IsolationLevel,
        savepoint_dialect: SavepointDialect,
    ) -> Self {
        Self::assemble_for_test(
            TransactionConnection::Regular(handles),
            conn_id,
            state,
            isolation_level,
            savepoint_dialect,
            TransactionAccessMode::ReadWrite,
            LockTimeout::engine_default(),
        )
    }

    /// Test-only constructor that lets the caller pin both the dialect and
    /// the access mode. See [`for_test`] for caveats.
    #[doc(hidden)]
    pub fn for_test_with_access_mode(
        handles: SharedHandleManager,
        conn_id: u32,
        state: TransactionState,
        isolation_level: IsolationLevel,
        savepoint_dialect: SavepointDialect,
        access_mode: TransactionAccessMode,
    ) -> Self {
        Self::assemble_for_test(
            TransactionConnection::Regular(handles),
            conn_id,
            state,
            isolation_level,
            savepoint_dialect,
            access_mode,
            LockTimeout::engine_default(),
        )
    }

    /// Test-only constructor that lets the caller pin every dimension
    /// (dialect + access mode + lock timeout). See [`for_test`] for
    /// caveats.
    #[doc(hidden)]
    pub fn for_test_with_lock_timeout(
        handles: SharedHandleManager,
        conn_id: u32,
        state: TransactionState,
        isolation_level: IsolationLevel,
        savepoint_dialect: SavepointDialect,
        access_mode: TransactionAccessMode,
        lock_timeout: LockTimeout,
    ) -> Self {
        Self::assemble_for_test(
            TransactionConnection::Regular(handles),
            conn_id,
            state,
            isolation_level,
            savepoint_dialect,
            access_mode,
            lock_timeout,
        )
    }

    /// Test-only constructor that builds a fresh empty `SharedHandleManager`
    /// internally — useful for **integration tests** (`tests/`) that cannot
    /// import the private `handles` module.
    /// Hidden from rustdoc; not part of the public API surface.
    #[doc(hidden)]
    pub fn for_test_no_conn(
        state: TransactionState,
        isolation_level: IsolationLevel,
        savepoint_dialect: SavepointDialect,
    ) -> Self {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        Self::assemble_for_test(
            TransactionConnection::Regular(handles),
            // u32::MAX is guaranteed not to collide with a real connection id;
            // identifier validation runs BEFORE any handle lookup so this is
            // safe for tests that only exercise `savepoint_*` validation paths.
            u32::MAX,
            state,
            isolation_level,
            savepoint_dialect,
            TransactionAccessMode::ReadWrite,
            LockTimeout::engine_default(),
        )
    }

    pub(crate) fn assemble_for_test(
        connection: TransactionConnection,
        conn_id: u32,
        state: TransactionState,
        isolation_level: IsolationLevel,
        savepoint_dialect: SavepointDialect,
        access_mode: TransactionAccessMode,
        lock_timeout: LockTimeout,
    ) -> Self {
        Self {
            connection,
            conn_id,
            state: Arc::new(Mutex::new(state)),
            isolation_level,
            savepoint_dialect,
            access_mode,
            lock_timeout,
        }
    }
}

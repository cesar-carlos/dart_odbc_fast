mod dialect_sql;
mod savepoint;
mod test_helpers;

pub(crate) use savepoint::resolve_savepoint_dialect_for_engine;
pub use savepoint::{Savepoint, SavepointDialect};

use crate::engine::core::{ENGINE_SQLSERVER, ENGINE_UNKNOWN};
use crate::engine::dbms_info::DbmsInfo;
use crate::engine::identifier::{quote_identifier, validate_identifier, IdentifierQuoting};
use crate::error::{OdbcError, Result};
use crate::handles::{HandleManager, SharedHandleManager};
use crate::pool::SharedPooledConnection;
use dialect_sql::{
    access_mode_is_unsupported_noop, build_access_mode_sql, build_isolation_sql,
    build_lock_timeout_sql, lock_timeout_is_unsupported_skip, IsolationSql,
};
use savepoint::quoting_for;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IsolationLevel {
    ReadUncommitted,
    ReadCommitted,
    RepeatableRead,
    Serializable,
}

/// Whether a transaction is allowed to mutate state.
///
/// Equivalent of the SQL-92 `READ ONLY` / `READ WRITE` modifier on
/// `SET TRANSACTION`. Setting `ReadOnly` lets the engine skip locking
/// (PostgreSQL, MySQL/MariaDB), pick a snapshot path (Oracle), or simply
/// reject any DML attempt during the transaction. Engines that have no
/// equivalent (SQL Server, SQLite, Snowflake) treat this as a no-op so
/// callers can program against the abstraction unconditionally.
///
/// Sprint 4.1 — see `CHANGELOG.md` `[3.4.0]`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransactionAccessMode {
    /// Default. Transaction may execute any DML/DDL allowed by the user's
    /// privileges. Equivalent to `READ WRITE` on SQL-92 engines.
    ReadWrite,
    /// Transaction may not execute DML or DDL. Drivers that support the
    /// hint use it to skip locking and (where applicable) take a
    /// snapshot read path.
    ReadOnly,
}

impl TransactionAccessMode {
    /// FFI mapping (stable):
    /// - `0` → `ReadWrite` (default)
    /// - `1` → `ReadOnly`
    /// - anything else → `ReadWrite`
    pub fn from_u32(v: u32) -> Self {
        match v {
            1 => Self::ReadOnly,
            _ => Self::ReadWrite,
        }
    }

    /// SQL-92 keyword for the `SET TRANSACTION ... <KW>` modifier.
    pub(crate) fn to_sql_keyword(self) -> &'static str {
        match self {
            Self::ReadOnly => "READ ONLY",
            Self::ReadWrite => "READ WRITE",
        }
    }

    pub fn is_read_only(self) -> bool {
        matches!(self, Self::ReadOnly)
    }
}

/// Maximum time a statement inside the transaction will wait to acquire
/// a lock before failing with the engine's lock-timeout error.
///
/// Sprint 4.2 — see `CHANGELOG.md` `[3.4.0]`.
///
/// The wire/FFI representation is `u32` *milliseconds*:
///
/// - `0` → engine default (no override; behaves exactly like the v3.3.0
///   transaction path).
/// - any other value → that many milliseconds.
///
/// The struct is purely a typed wrapper; the engine matrix lives in
/// [`Transaction::apply_lock_timeout`].
///
/// **Engine matrix**:
///
/// | Engine               | SQL                                            | Native unit    |
/// | -------------------- | ---------------------------------------------- | -------------- |
/// | SQL Server           | `SET LOCK_TIMEOUT <n>`                         | ms             |
/// | PostgreSQL           | `SET LOCAL lock_timeout = '<n>ms'`             | ms             |
/// | MySQL / MariaDB      | `SET SESSION innodb_lock_wait_timeout = <s>`   | s (rounded up) |
/// | DB2                  | `SET CURRENT LOCK TIMEOUT <s>`                 | s (rounded up) |
/// | SQLite               | `PRAGMA busy_timeout = <n>`                    | ms             |
/// | Oracle / Snowflake / others | no-op (logged at debug)                  | —              |
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LockTimeout {
    millis: Option<u32>,
}

impl LockTimeout {
    /// No override — let the engine apply its default lock-timeout.
    pub const fn engine_default() -> Self {
        Self { millis: None }
    }

    /// Build a [`LockTimeout`] from a millisecond count.
    /// `0` is interpreted as "engine default" so the wire `0` stays
    /// equivalent to "no override" and round-trips through the FFI
    /// without surprises.
    pub fn from_millis(millis: u32) -> Self {
        if millis == 0 {
            Self { millis: None }
        } else {
            Self {
                millis: Some(millis),
            }
        }
    }

    /// Build a [`LockTimeout`] from a [`Duration`]. Sub-millisecond
    /// precision is rounded up so a request of "wait at least 1µs"
    /// never silently becomes "engine default".
    pub fn from_duration(dur: Duration) -> Self {
        let raw_ms = dur.as_millis();
        if raw_ms == 0 && !dur.is_zero() {
            // Sub-ms positive duration → bump to 1ms to honour intent
            // ("wait a tiny bit") rather than collapse to "engine
            // default".
            return Self { millis: Some(1) };
        }
        if raw_ms == 0 {
            return Self::engine_default();
        }
        let clamped = u32::try_from(raw_ms).unwrap_or(u32::MAX);
        Self {
            millis: Some(clamped),
        }
    }

    /// Returns `true` when the caller wants to fall through to the
    /// engine default (no `SET` is emitted).
    pub fn is_engine_default(self) -> bool {
        self.millis.is_none()
    }

    /// Returns the override in milliseconds, or `None` for "engine
    /// default".
    pub fn millis(self) -> Option<u32> {
        self.millis
    }

    /// Convert the override to *seconds*, rounded up. Used by engines
    /// that natively express lock waits in seconds (MySQL, DB2). Sub-
    /// second overrides become 1 second so we never silently relax
    /// the caller's bound.
    pub(crate) fn millis_as_seconds_rounded_up(self) -> Option<u32> {
        self.millis.map(|ms| ms.div_ceil(1000).max(1))
    }
}

impl Default for LockTimeout {
    fn default() -> Self {
        Self::engine_default()
    }
}

impl IsolationLevel {
    pub fn from_u32(v: u32) -> Option<Self> {
        match v {
            0 => Some(Self::ReadUncommitted),
            1 => Some(Self::ReadCommitted),
            2 => Some(Self::RepeatableRead),
            3 => Some(Self::Serializable),
            _ => None,
        }
    }

    /// SQL clause for `SET TRANSACTION ISOLATION LEVEL <level>` (SQL‑92).
    /// Used when ODBC SQL_ATTR_TXN_ISOLATION is not available (e.g. odbc-api Connection).
    pub(crate) fn to_sql_keyword(self) -> &'static str {
        match self {
            Self::ReadUncommitted => "READ UNCOMMITTED",
            Self::ReadCommitted => "READ COMMITTED",
            Self::RepeatableRead => "REPEATABLE READ",
            Self::Serializable => "SERIALIZABLE",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransactionState {
    None,
    Active,
    Committed,
    RolledBack,
}

#[derive(Clone)]
pub(crate) enum TransactionConnection {
    Regular(SharedHandleManager),
    Pooled(SharedPooledConnection),
}

impl TransactionConnection {
    fn with_connection<F, T>(&self, conn_id: u32, op: &str, f: F) -> Result<T>
    where
        F: FnOnce(&odbc_api::Connection<'static>) -> Result<T>,
    {
        match self {
            Self::Regular(handles) => {
                let conn_arc = {
                    let h = handles.lock().map_err(|_| {
                        OdbcError::InternalError(format!("Failed to lock handles for {op}"))
                    })?;
                    h.get_connection(conn_id)?
                };
                let conn = conn_arc.lock().map_err(|_| {
                    OdbcError::InternalError("Failed to lock connection".to_string())
                })?;
                f(conn.connection())
            }
            Self::Pooled(pooled) => {
                let conn = pooled.lock().map_err(|_| {
                    OdbcError::InternalError("Failed to lock pooled connection".to_string())
                })?;
                f(conn.get_connection())
            }
        }
    }

    fn with_connection_mut<F, T>(&self, conn_id: u32, op: &str, f: F) -> Result<T>
    where
        F: FnOnce(&mut odbc_api::Connection<'static>) -> Result<T>,
    {
        match self {
            Self::Regular(handles) => {
                let conn_arc = {
                    let h = handles.lock().map_err(|_| {
                        OdbcError::InternalError(format!("Failed to lock handles for {op}"))
                    })?;
                    h.get_connection(conn_id)?
                };
                let mut conn = conn_arc.lock().map_err(|_| {
                    OdbcError::InternalError("Failed to lock connection".to_string())
                })?;
                f(conn.connection_mut())
            }
            Self::Pooled(pooled) => {
                let mut conn = pooled.lock().map_err(|_| {
                    OdbcError::InternalError("Failed to lock pooled connection".to_string())
                })?;
                f(conn.get_connection_mut())
            }
        }
    }

    fn detect_engine_and_dialect(
        &self,
        conn_id: u32,
        requested: SavepointDialect,
    ) -> (String, SavepointDialect) {
        match requested {
            SavepointDialect::Sql92 => (ENGINE_UNKNOWN.to_string(), SavepointDialect::Sql92),
            SavepointDialect::SqlServer => {
                (ENGINE_SQLSERVER.to_string(), SavepointDialect::SqlServer)
            }
            SavepointDialect::Auto => {
                match self.with_connection(conn_id, "detect transaction dialect", DbmsInfo::detect)
                {
                    Ok(info) => {
                        let dialect = resolve_savepoint_dialect_for_engine(&info.engine);
                        (info.engine, dialect)
                    }
                    Err(e) => {
                        log::warn!(
                        "Transaction::begin: SQLGetInfo failed for conn_id {conn_id} ({e}); falling back to Sql92"
                    );
                        (ENGINE_UNKNOWN.to_string(), SavepointDialect::Sql92)
                    }
                }
            }
        }
    }

    fn handles(&self) -> Option<SharedHandleManager> {
        match self {
            Self::Regular(handles) => Some(handles.clone()),
            Self::Pooled(_) => None,
        }
    }
}

pub struct Transaction {
    connection: TransactionConnection,
    conn_id: u32,
    state: Arc<Mutex<TransactionState>>,
    isolation_level: IsolationLevel,
    savepoint_dialect: SavepointDialect,
    access_mode: TransactionAccessMode,
    lock_timeout: LockTimeout,
}

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
            Self::apply_isolation(conn, &engine_id, isolation_level)?;

            // Access mode must follow isolation. Oracle is special-cased inside
            // `apply_access_mode` because `SET TRANSACTION READ ONLY` overrides
            // the previous isolation choice on that engine.
            Self::apply_access_mode(conn, &engine_id, access_mode)?;

            // Lock timeout is engine-aware too. PostgreSQL uses `SET LOCAL`
            // (so it auto-resets on commit/rollback); other engines apply
            // session-wide. The override is best-effort: failure here would
            // prevent the transaction from starting, which is too coarse,
            // so we surface the engine error verbatim and let the caller
            // decide.
            Self::apply_lock_timeout(conn, &engine_id, lock_timeout)?;

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

    /// Vendor-aware isolation-level setter.
    fn apply_isolation(
        conn: &mut odbc_api::Connection<'static>,
        engine_id: &str,
        level: IsolationLevel,
    ) -> Result<()> {
        match build_isolation_sql(engine_id, level)? {
            IsolationSql::Execute(sql) => conn
                .execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from),
            IsolationSql::Skip { engine_id, level } => {
                log::debug!(
                    "apply_isolation: engine {engine_id:?} ignores per-transaction isolation; \
                     requested {level:?} silently skipped"
                );
                Ok(())
            }
        }
    }

    /// Apply the `READ ONLY` / `READ WRITE` access mode to the connection
    /// using a vendor-aware strategy.
    ///
    /// Engine matrix:
    ///
    /// | Engine                       | Behaviour                                                      |
    /// | ---------------------------- | -------------------------------------------------------------- |
    /// | PostgreSQL                   | `SET TRANSACTION READ ONLY` / `READ WRITE`                     |
    /// | MySQL / MariaDB              | `SET TRANSACTION READ ONLY` / `READ WRITE`                     |
    /// | DB2                          | `SET TRANSACTION READ ONLY` / `READ WRITE`                     |
    /// | Oracle                       | `SET TRANSACTION READ ONLY` (no-op for `READ WRITE` — default) |
    /// | SQL Server / SQLite / others | log + skip; no native equivalent                                |
    ///
    /// `READ WRITE` is the engine default everywhere, so for any engine
    /// without an explicit clause we treat it as a no-op rather than emit
    /// a redundant `SET`. This keeps the connection's textual session log
    /// clean and avoids spurious failures on engines that reject the
    /// keyword.
    fn apply_access_mode(
        conn: &mut odbc_api::Connection<'static>,
        engine_id: &str,
        access_mode: TransactionAccessMode,
    ) -> Result<()> {
        if let Some(sql) = build_access_mode_sql(engine_id, access_mode) {
            return conn
                .execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from);
        }

        if access_mode.is_read_only() && access_mode_is_unsupported_noop(engine_id) {
            log::debug!(
                "apply_access_mode: engine {engine_id:?} has no READ ONLY transaction \
                 hint; silently treating as READ WRITE. Application-level \
                 enforcement (DENY UPDATE/INSERT/DELETE) is the only option \
                 on this engine."
            );
        }
        Ok(())
    }

    /// Apply the per-transaction lock timeout to the connection using a
    /// vendor-aware strategy. See [`LockTimeout`] for the engine matrix.
    ///
    /// **No-op when [`LockTimeout::is_engine_default`]**, which is the
    /// universal default — the engine's existing setting is left
    /// untouched and no `SET` is emitted. This keeps the connection's
    /// session log clean for callers that don't need the override and
    /// avoids paying for it in the hot path.
    fn apply_lock_timeout(
        conn: &mut odbc_api::Connection<'static>,
        engine_id: &str,
        lock_timeout: LockTimeout,
    ) -> Result<()> {
        if let Some(sql) = build_lock_timeout_sql(engine_id, lock_timeout)? {
            return conn
                .execute(&sql, (), None)
                .map(|_| ())
                .map_err(OdbcError::from);
        }

        if lock_timeout.is_engine_default() {
            return Ok(());
        }

        let Some(ms) = lock_timeout.millis() else {
            return Err(OdbcError::InternalError(
                "apply_lock_timeout: non-default LockTimeout missing millis".to_string(),
            ));
        };
        if lock_timeout_is_unsupported_skip(engine_id) {
            if matches!(
                engine_id,
                crate::engine::core::ENGINE_ORACLE | crate::engine::core::ENGINE_SNOWFLAKE
            ) {
                log::debug!(
                    "apply_lock_timeout: engine {engine_id:?} has no per-transaction \
                     lock-timeout hint; requested {ms}ms silently skipped. \
                     Use per-statement options (Oracle: FOR UPDATE WAIT n; \
                     Snowflake: STATEMENT_TIMEOUT_IN_SECONDS) instead."
                );
            } else {
                log::debug!(
                    "apply_lock_timeout: engine {engine_id:?} is not in the lock-timeout \
                     matrix; requested {ms}ms silently skipped. File an issue if you \
                     need first-class support."
                );
            }
        }
        Ok(())
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

    /// Validate, quote and execute a `SAVEPOINT` (or `SAVE TRANSACTION` on
    /// SQL Server) for `name`. Used by the FFI layer so that all callers go
    /// through identifier validation (B1 fix — closes A1 regression via FFI).
    pub fn savepoint_create(&self, name: &str) -> Result<()> {
        validate_identifier(name)?;
        let qname = quote_identifier(name, quoting_for(self.savepoint_dialect))?;
        let sql = match self.savepoint_dialect {
            SavepointDialect::SqlServer => format!("SAVE TRANSACTION {qname}"),
            // `Auto` should never reach this point because `begin_with_dialect`
            // resolves it; treat it as Sql92 defensively.
            SavepointDialect::Sql92 | SavepointDialect::Auto => format!("SAVEPOINT {qname}"),
        };
        self.execute_sql(&sql)
    }

    /// Validate, quote and emit a `ROLLBACK TO [SAVEPOINT] <name>` for the
    /// transaction's dialect.
    pub fn savepoint_rollback_to(&self, name: &str) -> Result<()> {
        validate_identifier(name)?;
        let qname = quote_identifier(name, quoting_for(self.savepoint_dialect))?;
        let sql = match self.savepoint_dialect {
            SavepointDialect::SqlServer => format!("ROLLBACK TRANSACTION {qname}"),
            SavepointDialect::Sql92 | SavepointDialect::Auto => {
                format!("ROLLBACK TO SAVEPOINT {qname}")
            }
        };
        self.execute_sql(&sql)
    }

    /// Validate, quote and emit `RELEASE SAVEPOINT <name>`. SQL Server has no
    /// equivalent (savepoints are released on commit/rollback) so this is a
    /// successful no-op there.
    pub fn savepoint_release(&self, name: &str) -> Result<()> {
        validate_identifier(name)?;
        match self.savepoint_dialect {
            SavepointDialect::SqlServer => Ok(()),
            SavepointDialect::Sql92 | SavepointDialect::Auto => {
                let qname = quote_identifier(name, IdentifierQuoting::DoubleQuote)?;
                let sql = format!("RELEASE SAVEPOINT {qname}");
                self.execute_sql(&sql)
            }
        }
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

#[cfg(test)]
mod tests;

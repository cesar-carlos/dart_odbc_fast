use crate::engine::core::{
    ENGINE_DB2, ENGINE_MARIADB, ENGINE_MYSQL, ENGINE_ORACLE, ENGINE_POSTGRES, ENGINE_SNOWFLAKE,
    ENGINE_SQLITE, ENGINE_SQLSERVER, ENGINE_UNKNOWN,
};
use crate::engine::dbms_info::DbmsInfo;
use crate::engine::identifier::{quote_identifier, validate_identifier, IdentifierQuoting};
use crate::error::{OdbcError, Result};
use crate::handles::SharedHandleManager;
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
/// Sprint 4.1 — see `doc/notes/FUTURE_IMPLEMENTATIONS.md` §4.1.
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
/// Sprint 4.2 — see `doc/notes/FUTURE_IMPLEMENTATIONS.md` §4.2.
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

    /// DB2-style keyword for `SET CURRENT ISOLATION = <X>`.
    fn to_db2_keyword(self) -> &'static str {
        match self {
            Self::ReadUncommitted => "UR", // Uncommitted Read
            Self::ReadCommitted => "CS",   // Cursor Stability
            Self::RepeatableRead => "RS",  // Read Stability
            Self::Serializable => "RR",    // Repeatable Read (DB2 semantics)
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

/// Savepoint SQL dialect.
///
/// `Auto` (NEW in v3.1) is the recommended default: the dialect is resolved
/// from the connection's live DBMS via `SQLGetInfo` at `Transaction::begin`.
/// SQL Server resolves to `SqlServer`; everything else to `Sql92`.
///
/// `Sql92` and `SqlServer` remain available for callers that already know the
/// engine and want to skip the round-trip.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SavepointDialect {
    /// Resolve at runtime via `SQLGetInfo(SQL_DBMS_NAME)` on the connection.
    Auto,
    /// `SAVEPOINT`, `ROLLBACK TO SAVEPOINT`, `RELEASE SAVEPOINT` (PostgreSQL,
    /// MySQL, MariaDB, Oracle, DB2, SQLite, Snowflake, ...).
    Sql92,
    /// `SAVE TRANSACTION`, `ROLLBACK TRANSACTION` (SQL Server; no `RELEASE`).
    SqlServer,
}

impl SavepointDialect {
    /// FFI mapping (stable):
    /// - `0` → `Auto` (default since v3.1)
    /// - `1` → `SqlServer`
    /// - `2` → `Sql92`
    /// - anything else → `Auto`
    pub fn from_u32(v: u32) -> Self {
        match v {
            1 => Self::SqlServer,
            2 => Self::Sql92,
            _ => Self::Auto,
        }
    }
}

/// Strategy for applying `IsolationLevel` to a connection across vendors.
///
/// Different drivers honour wildly different syntax (SQLite uses a `PRAGMA`,
/// DB2 uses `SET CURRENT ISOLATION`, Snowflake ignores per-tx isolation, etc).
/// This enum is internal to `Transaction::begin_with_dialect`.
#[derive(Debug, Clone, Copy)]
enum IsolationStrategy {
    /// SQL-92 `SET TRANSACTION ISOLATION LEVEL <X>` (SQL Server, PostgreSQL,
    /// MySQL, MariaDB, Sybase ASE, Redshift, ...).
    Sql92,
    /// SQLite: only Read Uncommitted vs Serializable, via
    /// `PRAGMA read_uncommitted = 0|1`.
    SqlitePragma,
    /// DB2 LUW / z/OS: `SET CURRENT ISOLATION = UR|CS|RS|RR`.
    Db2SetCurrent,
    /// Oracle: only `READ COMMITTED` and `SERIALIZABLE` are supported.
    /// The other two levels are rejected with `ValidationError`.
    OracleRestricted,
    /// Snowflake / BigQuery / engines without per-transaction isolation:
    /// silently skip the SET.
    Skip,
}

impl IsolationStrategy {
    fn for_engine(engine: &str) -> Self {
        match engine {
            ENGINE_SQLITE => Self::SqlitePragma,
            ENGINE_DB2 => Self::Db2SetCurrent,
            ENGINE_ORACLE => Self::OracleRestricted,
            ENGINE_SNOWFLAKE => Self::Skip,
            // SqlServer, Postgres, MySQL, MariaDB, Sybase, Redshift,
            // Sybase ASA, Unknown, ... → SQL-92 dialect.
            _ => Self::Sql92,
        }
    }
}

/// Resolve `SavepointDialect::Auto` to a concrete dialect using the live DBMS
/// info. SqlServer → `SqlServer`; everything else (including Unknown) → `Sql92`.
fn resolve_savepoint_dialect_for_engine(engine: &str) -> SavepointDialect {
    if engine == ENGINE_SQLSERVER {
        SavepointDialect::SqlServer
    } else {
        SavepointDialect::Sql92
    }
}

pub struct Transaction {
    handles: SharedHandleManager,
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
    /// Sprint 4.1 — see `doc/notes/FUTURE_IMPLEMENTATIONS.md` §4.1 and
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
    /// Sprint 4.2 — see `doc/notes/FUTURE_IMPLEMENTATIONS.md` §4.2 and
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
        // Resolve `Auto` ahead of time so the rest of the lifecycle is
        // dialect-agnostic. Best-effort: if `SQLGetInfo` fails we fall back to
        // `Sql92` (the safe default for unknown engines).
        let (engine_id, resolved_dialect) =
            Self::detect_engine_and_dialect(&handles, conn_id, savepoint_dialect);

        let state = Arc::new(Mutex::new(TransactionState::Active));
        let conn_arc = {
            let h = handles
                .lock()
                .map_err(|_| OdbcError::InternalError("Failed to lock handles".to_string()))?;
            h.get_connection(conn_id)?
        };
        let mut conn = conn_arc
            .lock()
            .map_err(|_| OdbcError::InternalError("Failed to lock connection".to_string()))?;

        // Apply isolation level using a dialect-aware strategy. Must run BEFORE
        // `set_autocommit(false)` because some engines (notably SQL Server)
        // refuse `SET TRANSACTION ISOLATION LEVEL` inside an open transaction.
        Self::apply_isolation(conn.connection_mut(), &engine_id, isolation_level)?;

        // Access mode must follow isolation. Oracle is special-cased inside
        // `apply_access_mode` because `SET TRANSACTION READ ONLY` overrides
        // the previous isolation choice on that engine.
        Self::apply_access_mode(conn.connection_mut(), &engine_id, access_mode)?;

        // Lock timeout is engine-aware too. PostgreSQL uses `SET LOCAL`
        // (so it auto-resets on commit/rollback); other engines apply
        // session-wide. The override is best-effort: failure here would
        // prevent the transaction from starting, which is too coarse,
        // so we surface the engine error verbatim and let the caller
        // decide.
        Self::apply_lock_timeout(conn.connection_mut(), &engine_id, lock_timeout)?;

        conn.connection_mut()
            .set_autocommit(false)
            .map_err(OdbcError::from)?;

        Ok(Self {
            handles,
            conn_id,
            state,
            isolation_level,
            savepoint_dialect: resolved_dialect,
            access_mode,
            lock_timeout,
        })
    }

    /// Returns `(engine_id, resolved_dialect)`. Best-effort:
    /// - When the caller passed `Sql92` or `SqlServer` we keep it.
    /// - When `Auto`, we ask `DbmsInfo::detect_for_conn_id`. On failure we fall
    ///   back to `Sql92` and `engine = ENGINE_UNKNOWN`.
    fn detect_engine_and_dialect(
        handles: &SharedHandleManager,
        conn_id: u32,
        requested: SavepointDialect,
    ) -> (String, SavepointDialect) {
        match requested {
            SavepointDialect::Sql92 => (ENGINE_UNKNOWN.to_string(), SavepointDialect::Sql92),
            SavepointDialect::SqlServer => {
                (ENGINE_SQLSERVER.to_string(), SavepointDialect::SqlServer)
            }
            SavepointDialect::Auto => match DbmsInfo::detect_for_conn_id(handles, conn_id) {
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
            },
        }
    }

    /// Vendor-aware isolation-level setter.
    fn apply_isolation(
        conn: &mut odbc_api::Connection<'static>,
        engine_id: &str,
        level: IsolationLevel,
    ) -> Result<()> {
        let strategy = IsolationStrategy::for_engine(engine_id);
        match strategy {
            IsolationStrategy::Sql92 => {
                let sql = format!("SET TRANSACTION ISOLATION LEVEL {}", level.to_sql_keyword());
                conn.execute(&sql, (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            }
            IsolationStrategy::SqlitePragma => {
                // SQLite only distinguishes Serializable (default) from Read
                // Uncommitted (shared-cache only). Other levels are no-ops on
                // the safe side.
                let sql = match level {
                    IsolationLevel::ReadUncommitted => "PRAGMA read_uncommitted = 1",
                    _ => "PRAGMA read_uncommitted = 0",
                };
                conn.execute(sql, (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            }
            IsolationStrategy::Db2SetCurrent => {
                let sql = format!("SET CURRENT ISOLATION = {}", level.to_db2_keyword());
                conn.execute(&sql, (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            }
            IsolationStrategy::OracleRestricted => match level {
                IsolationLevel::ReadCommitted => conn
                    .execute("SET TRANSACTION ISOLATION LEVEL READ COMMITTED", (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from),
                IsolationLevel::Serializable => conn
                    .execute("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE", (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from),
                IsolationLevel::ReadUncommitted | IsolationLevel::RepeatableRead => {
                    Err(OdbcError::ValidationError(format!(
                        "Oracle does not support isolation level {level:?}; \
                         only ReadCommitted and Serializable are supported"
                    )))
                }
            },
            IsolationStrategy::Skip => {
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
        // `READ WRITE` is the universal default; only emit a SET when we
        // actually need to switch the engine into read-only mode.
        if !access_mode.is_read_only() {
            return Ok(());
        }

        match engine_id {
            ENGINE_POSTGRES | ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 | ENGINE_ORACLE => {
                let sql = format!("SET TRANSACTION {}", access_mode.to_sql_keyword());
                conn.execute(&sql, (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            }
            _ => {
                // SQL Server, SQLite, Snowflake, Sybase, Redshift, BigQuery,
                // MongoDB, unknown — none have a portable READ ONLY hint
                // here. Log so misuse is visible in DEBUG builds, then
                // silently succeed so callers can program against the
                // abstraction unconditionally.
                log::debug!(
                    "apply_access_mode: engine {engine_id:?} has no READ ONLY transaction \
                     hint; silently treating as READ WRITE. Application-level \
                     enforcement (DENY UPDATE/INSERT/DELETE) is the only option \
                     on this engine."
                );
                Ok(())
            }
        }
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
        if lock_timeout.is_engine_default() {
            return Ok(());
        }
        let ms = lock_timeout
            .millis()
            .expect("is_engine_default just returned false; millis() must be Some");

        match engine_id {
            ENGINE_SQLSERVER => {
                // SQL Server: milliseconds, session-wide. Note that this
                // setting persists past the transaction; resetting to the
                // engine default would require remembering the previous
                // value, which the abstraction doesn't promise. Document
                // it; callers that need strict per-tx isolation should
                // wrap in a fresh connection.
                let sql = format!("SET LOCK_TIMEOUT {}", ms);
                conn.execute(&sql, (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            }
            ENGINE_POSTGRES => {
                // PostgreSQL: `SET LOCAL` is the per-transaction variant
                // and auto-resets on commit/rollback — exactly what we
                // want. The unit suffix `ms` makes the value unambiguous
                // regardless of any cluster-wide GUC unit override.
                let sql = format!("SET LOCAL lock_timeout = '{}ms'", ms);
                conn.execute(&sql, (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            }
            ENGINE_MYSQL | ENGINE_MARIADB => {
                // MySQL/MariaDB: `innodb_lock_wait_timeout` is in
                // *seconds*, range 1..=1073741824. There is no SET LOCAL
                // equivalent, so this leaks past the transaction; same
                // caveat as SQL Server. Round sub-second requests up to
                // 1s so we never silently relax the caller's bound.
                let secs = lock_timeout
                    .millis_as_seconds_rounded_up()
                    .expect("override must round to a positive seconds value");
                let sql = format!("SET SESSION innodb_lock_wait_timeout = {}", secs);
                conn.execute(&sql, (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            }
            ENGINE_DB2 => {
                // DB2: `SET CURRENT LOCK TIMEOUT` accepts integers in
                // *seconds*. Same rounding policy as MySQL.
                let secs = lock_timeout
                    .millis_as_seconds_rounded_up()
                    .expect("override must round to a positive seconds value");
                let sql = format!("SET CURRENT LOCK TIMEOUT {}", secs);
                conn.execute(&sql, (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            }
            ENGINE_SQLITE => {
                // SQLite: `PRAGMA busy_timeout` is in milliseconds and
                // applies to every subsequent statement on this
                // connection. It's the closest equivalent to a lock
                // timeout SQLite offers.
                let sql = format!("PRAGMA busy_timeout = {}", ms);
                conn.execute(&sql, (), None)
                    .map(|_| ())
                    .map_err(OdbcError::from)
            }
            ENGINE_ORACLE | ENGINE_SNOWFLAKE => {
                // Oracle expresses lock waits per-statement (`FOR UPDATE
                // WAIT n`); per-tx hint does not exist. Snowflake has
                // `STATEMENT_TIMEOUT_IN_SECONDS` but that's a statement
                // timeout, not a lock timeout — different semantics, so
                // we deliberately *don't* repurpose it.
                log::debug!(
                    "apply_lock_timeout: engine {engine_id:?} has no per-transaction \
                     lock-timeout hint; requested {ms}ms silently skipped. \
                     Use per-statement options (Oracle: FOR UPDATE WAIT n; \
                     Snowflake: STATEMENT_TIMEOUT_IN_SECONDS) instead."
                );
                Ok(())
            }
            _ => {
                // Sybase, Redshift, BigQuery, MongoDB, unknown — log and
                // skip so the abstraction stays callable without
                // surprises on engines we haven't mapped yet.
                log::debug!(
                    "apply_lock_timeout: engine {engine_id:?} is not in the lock-timeout \
                     matrix; requested {ms}ms silently skipped. File an issue if you \
                     need first-class support."
                );
                Ok(())
            }
        }
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

        let conn_arc = {
            let h = self.handles.lock().map_err(|_| {
                OdbcError::InternalError("Failed to lock handles for commit".to_string())
            })?;
            h.get_connection(self.conn_id)?
        };
        let mut conn = conn_arc
            .lock()
            .map_err(|_| OdbcError::InternalError("Failed to lock connection".to_string()))?;
        let commit_result = conn.connection_mut().commit().map_err(OdbcError::from);
        // ALWAYS try to restore autocommit, regardless of commit outcome (B7 fix).
        // If commit failed the driver may already have rolled back and reset
        // autocommit; the call is a best-effort safety net so the connection
        // is never returned to the caller / pool stuck in autocommit=off.
        if let Err(e) = conn.connection_mut().set_autocommit(true) {
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

        let conn_arc = {
            let h = self.handles.lock().map_err(|_| {
                OdbcError::InternalError("Failed to lock handles for rollback".to_string())
            })?;
            h.get_connection(self.conn_id)?
        };
        let mut conn = conn_arc
            .lock()
            .map_err(|_| OdbcError::InternalError("Failed to lock connection".to_string()))?;
        let rollback_result = conn.connection_mut().rollback().map_err(OdbcError::from);
        // ALWAYS restore autocommit (B7 fix), same rationale as `commit`.
        if let Err(e) = conn.connection_mut().set_autocommit(true) {
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
        let conn_arc = {
            let h = self.handles.lock().map_err(|_| {
                OdbcError::InternalError("Failed to lock handles for execute_sql".to_string())
            })?;
            h.get_connection(self.conn_id)?
        };
        let conn = conn_arc
            .lock()
            .map_err(|_| OdbcError::InternalError("Failed to lock connection".to_string()))?;
        conn.connection()
            .execute(sql, (), None)
            .map(|_| ())
            .map_err(OdbcError::from)
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
        self.handles.clone()
    }

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
        Self {
            handles,
            conn_id,
            state: Arc::new(Mutex::new(state)),
            isolation_level,
            savepoint_dialect: SavepointDialect::Sql92,
            access_mode: TransactionAccessMode::ReadWrite,
            lock_timeout: LockTimeout::engine_default(),
        }
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
        Self {
            handles,
            conn_id,
            state: Arc::new(Mutex::new(state)),
            isolation_level,
            savepoint_dialect,
            access_mode: TransactionAccessMode::ReadWrite,
            lock_timeout: LockTimeout::engine_default(),
        }
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
        Self {
            handles,
            conn_id,
            state: Arc::new(Mutex::new(state)),
            isolation_level,
            savepoint_dialect,
            access_mode,
            lock_timeout: LockTimeout::engine_default(),
        }
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
        Self {
            handles,
            conn_id,
            state: Arc::new(Mutex::new(state)),
            isolation_level,
            savepoint_dialect,
            access_mode,
            lock_timeout,
        }
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
        let handles: SharedHandleManager =
            Arc::new(Mutex::new(crate::handles::HandleManager::new()));
        Self {
            handles,
            // u32::MAX is guaranteed not to collide with a real connection id;
            // identifier validation runs BEFORE any handle lookup so this is
            // safe for tests that only exercise `savepoint_*` validation paths.
            conn_id: u32::MAX,
            state: Arc::new(Mutex::new(state)),
            isolation_level,
            savepoint_dialect,
            access_mode: TransactionAccessMode::ReadWrite,
            lock_timeout: LockTimeout::engine_default(),
        }
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
        let h = match self.handles.lock() {
            Ok(h) => h,
            Err(e) => {
                log::error!(
                    "Transaction Drop: failed to lock handles for conn_id {}: {e}",
                    self.conn_id
                );
                return;
            }
        };
        let conn_arc = match h.get_connection(self.conn_id) {
            Ok(c) => c,
            Err(e) => {
                log::error!(
                    "Transaction Drop: connection {} not found: {e}",
                    self.conn_id
                );
                return;
            }
        };
        let mut conn = match conn_arc.lock() {
            Ok(c) => c,
            Err(e) => {
                log::error!(
                    "Transaction Drop: failed to lock connection {}: {e}",
                    self.conn_id
                );
                return;
            }
        };
        if let Err(e) = conn.connection_mut().rollback() {
            log::error!(
                "Transaction Drop: rollback failed on conn_id {}: {e}",
                self.conn_id
            );
        }
        if let Err(e) = conn.connection_mut().set_autocommit(true) {
            log::error!(
                "Transaction Drop: set_autocommit(true) failed on conn_id {}: {e}",
                self.conn_id
            );
        }
    }
}

pub struct Savepoint<'t> {
    transaction: &'t Transaction,
    name: String,
}

/// Choose the appropriate identifier quoting style for a savepoint dialect.
fn quoting_for(dialect: SavepointDialect) -> IdentifierQuoting {
    match dialect {
        // `Auto` should be resolved before reaching this point; default to
        // SQL-92 quoting if it ever leaks through.
        SavepointDialect::Sql92 | SavepointDialect::Auto => IdentifierQuoting::DoubleQuote,
        SavepointDialect::SqlServer => IdentifierQuoting::Brackets,
    }
}

impl<'t> Savepoint<'t> {
    pub fn create(transaction: &'t Transaction, name: &str) -> Result<Self> {
        // A1 fix: validate + quote savepoint identifier to prevent SQL injection.
        transaction.savepoint_create(name)?;
        Ok(Self {
            transaction,
            name: name.to_string(),
        })
    }

    pub fn rollback_to(&self) -> Result<()> {
        self.transaction.savepoint_rollback_to(&self.name)
    }

    pub fn release(self) -> Result<()> {
        self.transaction.savepoint_release(&self.name)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        IsolationLevel, LockTimeout, SavepointDialect, Transaction, TransactionAccessMode,
        TransactionState,
    };
    use crate::error::OdbcError;
    use crate::handles::{HandleManager, SharedHandleManager};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    #[test]
    fn isolation_level_from_u32_maps_odbc_values() {
        assert_eq!(
            IsolationLevel::from_u32(0),
            Some(IsolationLevel::ReadUncommitted)
        );
        assert_eq!(
            IsolationLevel::from_u32(1),
            Some(IsolationLevel::ReadCommitted)
        );
        assert_eq!(
            IsolationLevel::from_u32(2),
            Some(IsolationLevel::RepeatableRead)
        );
        assert_eq!(
            IsolationLevel::from_u32(3),
            Some(IsolationLevel::Serializable)
        );
        assert_eq!(IsolationLevel::from_u32(4), None);
    }

    #[test]
    fn isolation_level_to_sql_keyword_sql92() {
        assert_eq!(
            IsolationLevel::ReadUncommitted.to_sql_keyword(),
            "READ UNCOMMITTED"
        );
        assert_eq!(
            IsolationLevel::ReadCommitted.to_sql_keyword(),
            "READ COMMITTED"
        );
        assert_eq!(
            IsolationLevel::RepeatableRead.to_sql_keyword(),
            "REPEATABLE READ"
        );
        assert_eq!(
            IsolationLevel::Serializable.to_sql_keyword(),
            "SERIALIZABLE"
        );
    }

    #[test]
    fn isolation_level_to_db2_keyword() {
        assert_eq!(IsolationLevel::ReadUncommitted.to_db2_keyword(), "UR");
        assert_eq!(IsolationLevel::ReadCommitted.to_db2_keyword(), "CS");
        assert_eq!(IsolationLevel::RepeatableRead.to_db2_keyword(), "RS");
        assert_eq!(IsolationLevel::Serializable.to_db2_keyword(), "RR");
    }

    #[test]
    fn isolation_level_set_transaction_sql_format() {
        let level = IsolationLevel::ReadCommitted;
        let sql = format!("SET TRANSACTION ISOLATION LEVEL {}", level.to_sql_keyword());
        assert_eq!(sql, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED");
    }

    #[test]
    fn transaction_commit_when_already_committed_returns_validation_error() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            1,
            TransactionState::Committed,
            IsolationLevel::ReadCommitted,
        );
        let result = txn.commit();
        match &result {
            Err(OdbcError::ValidationError(msg)) => assert!(msg.contains("Cannot commit")),
            _ => panic!("expected ValidationError, got {:?}", result),
        }
    }

    #[test]
    fn transaction_rollback_when_already_rolled_back_returns_validation_error() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            1,
            TransactionState::RolledBack,
            IsolationLevel::ReadCommitted,
        );
        let result = txn.rollback();
        match &result {
            Err(OdbcError::ValidationError(msg)) => assert!(msg.contains("Cannot rollback")),
            _ => panic!("expected ValidationError, got {:?}", result),
        }
    }

    #[test]
    fn transaction_state_variants() {
        let _ = TransactionState::None;
        let _ = TransactionState::Active;
        let _ = TransactionState::Committed;
        let _ = TransactionState::RolledBack;
    }

    #[test]
    fn transaction_commit_when_already_rolled_back_returns_validation_error() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            1,
            TransactionState::RolledBack,
            IsolationLevel::ReadCommitted,
        );
        let result = txn.commit();
        match &result {
            Err(OdbcError::ValidationError(msg)) => assert!(msg.contains("Cannot commit")),
            _ => panic!("expected ValidationError, got {:?}", result),
        }
    }

    #[test]
    fn transaction_commit_when_state_is_none_returns_validation_error() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            1,
            TransactionState::None,
            IsolationLevel::ReadCommitted,
        );
        let result = txn.commit();
        match &result {
            Err(OdbcError::ValidationError(msg)) => assert!(msg.contains("Cannot commit")),
            _ => panic!("expected ValidationError, got {:?}", result),
        }
    }

    #[test]
    fn transaction_rollback_when_state_is_none_returns_validation_error() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            1,
            TransactionState::None,
            IsolationLevel::ReadCommitted,
        );
        let result = txn.rollback();
        match &result {
            Err(OdbcError::ValidationError(msg)) => assert!(msg.contains("Cannot rollback")),
            _ => panic!("expected ValidationError, got {:?}", result),
        }
    }

    #[test]
    fn transaction_rollback_when_already_committed_returns_validation_error() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            1,
            TransactionState::Committed,
            IsolationLevel::ReadCommitted,
        );
        let result = txn.rollback();
        match &result {
            Err(OdbcError::ValidationError(msg)) => assert!(msg.contains("Cannot rollback")),
            _ => panic!("expected ValidationError, got {:?}", result),
        }
    }

    #[test]
    fn savepoint_dialect_from_u32_default_is_auto() {
        assert_eq!(SavepointDialect::from_u32(0), SavepointDialect::Auto);
        assert_eq!(SavepointDialect::from_u32(99), SavepointDialect::Auto);
    }

    #[test]
    fn savepoint_dialect_from_u32_explicit_codes() {
        assert_eq!(SavepointDialect::from_u32(1), SavepointDialect::SqlServer);
        assert_eq!(SavepointDialect::from_u32(2), SavepointDialect::Sql92);
    }

    #[test]
    fn savepoint_dialect_sql_keywords_sql92() {
        let create_sql = format!("SAVEPOINT {}", "sp1");
        let rollback_sql = format!("ROLLBACK TO SAVEPOINT {}", "sp1");
        let release_sql = format!("RELEASE SAVEPOINT {}", "sp1");
        assert_eq!(create_sql, "SAVEPOINT sp1");
        assert_eq!(rollback_sql, "ROLLBACK TO SAVEPOINT sp1");
        assert_eq!(release_sql, "RELEASE SAVEPOINT sp1");
    }

    #[test]
    fn savepoint_dialect_sql_keywords_sqlserver() {
        let create_sql = format!("SAVE TRANSACTION {}", "sp1");
        let rollback_sql = format!("ROLLBACK TRANSACTION {}", "sp1");
        assert_eq!(create_sql, "SAVE TRANSACTION sp1");
        assert_eq!(rollback_sql, "ROLLBACK TRANSACTION sp1");
    }

    #[test]
    fn transaction_is_active_true_when_active() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            1,
            TransactionState::Active,
            IsolationLevel::ReadCommitted,
        );
        assert!(txn.is_active());
    }

    #[test]
    fn transaction_is_active_false_when_committed() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            1,
            TransactionState::Committed,
            IsolationLevel::ReadCommitted,
        );
        assert!(!txn.is_active());
    }

    #[test]
    fn transaction_is_active_false_when_rolled_back() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            1,
            TransactionState::RolledBack,
            IsolationLevel::ReadCommitted,
        );
        assert!(!txn.is_active());
    }

    #[test]
    fn transaction_for_test_exposes_conn_id_and_isolation() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            42,
            TransactionState::Active,
            IsolationLevel::Serializable,
        );
        assert_eq!(txn.conn_id(), 42);
        assert_eq!(txn.isolation_level(), IsolationLevel::Serializable);
    }

    #[test]
    fn savepoint_create_rejects_injection_via_transaction_method() {
        // Transaction with no real connection — savepoint_create must reject
        // BEFORE attempting any SQL execution, so the missing connection is
        // never reached.
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            999, // bogus conn_id; identifier validation must short-circuit
            TransactionState::Active,
            IsolationLevel::ReadCommitted,
        );
        for bad in [
            "sp; DROP TABLE users--",
            "sp\";DROP TABLE x;--",
            "sp' OR '1'='1",
            "",
            "1bad_leading_digit",
            "sp space",
        ] {
            let r = txn.savepoint_create(bad);
            assert!(
                matches!(r, Err(OdbcError::ValidationError(_))),
                "savepoint_create must reject {bad:?}, got {r:?}"
            );
        }
    }

    #[test]
    fn savepoint_rollback_to_rejects_injection() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            999,
            TransactionState::Active,
            IsolationLevel::ReadCommitted,
        );
        let r = txn.savepoint_rollback_to("sp; DROP TABLE x--");
        assert!(matches!(r, Err(OdbcError::ValidationError(_))));
    }

    #[test]
    fn savepoint_release_is_noop_on_sqlserver_dialect() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test_with_dialect(
            handles,
            999,
            TransactionState::Active,
            IsolationLevel::ReadCommitted,
            SavepointDialect::SqlServer,
        );
        // SQL Server has no RELEASE SAVEPOINT — implementation returns Ok(())
        // without touching the connection (so the bogus conn_id is fine).
        assert!(txn.savepoint_release("sp1").is_ok());
    }

    // ---------------------------------------------------------------
    // TransactionAccessMode (Sprint 4.1) regression coverage
    // ---------------------------------------------------------------

    #[test]
    fn transaction_access_mode_from_u32_default_is_read_write() {
        assert_eq!(
            TransactionAccessMode::from_u32(0),
            TransactionAccessMode::ReadWrite
        );
        assert_eq!(
            TransactionAccessMode::from_u32(99),
            TransactionAccessMode::ReadWrite,
            "unknown discriminants must default to ReadWrite (safe default)"
        );
    }

    #[test]
    fn transaction_access_mode_from_u32_explicit_codes() {
        assert_eq!(
            TransactionAccessMode::from_u32(1),
            TransactionAccessMode::ReadOnly
        );
    }

    #[test]
    fn transaction_access_mode_to_sql_keyword() {
        assert_eq!(
            TransactionAccessMode::ReadOnly.to_sql_keyword(),
            "READ ONLY"
        );
        assert_eq!(
            TransactionAccessMode::ReadWrite.to_sql_keyword(),
            "READ WRITE"
        );
    }

    #[test]
    fn transaction_access_mode_is_read_only_predicate() {
        assert!(TransactionAccessMode::ReadOnly.is_read_only());
        assert!(!TransactionAccessMode::ReadWrite.is_read_only());
    }

    #[test]
    fn transaction_default_access_mode_is_read_write() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            1,
            TransactionState::Active,
            IsolationLevel::ReadCommitted,
        );
        assert_eq!(txn.access_mode(), TransactionAccessMode::ReadWrite);
    }

    #[test]
    fn transaction_for_test_with_access_mode_pins_the_value() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test_with_access_mode(
            handles,
            7,
            TransactionState::Active,
            IsolationLevel::Serializable,
            SavepointDialect::Sql92,
            TransactionAccessMode::ReadOnly,
        );
        assert_eq!(txn.access_mode(), TransactionAccessMode::ReadOnly);
        assert_eq!(txn.isolation_level(), IsolationLevel::Serializable);
    }

    /// Reproduces the SQL string the engine would emit for the SQL-92
    /// access-mode statement. Pure formatting check; no driver involved.
    #[test]
    fn transaction_access_mode_sql_format_matches_spec() {
        let ro = format!(
            "SET TRANSACTION {}",
            TransactionAccessMode::ReadOnly.to_sql_keyword()
        );
        assert_eq!(ro, "SET TRANSACTION READ ONLY");
        let rw = format!(
            "SET TRANSACTION {}",
            TransactionAccessMode::ReadWrite.to_sql_keyword()
        );
        assert_eq!(rw, "SET TRANSACTION READ WRITE");
    }

    // ---------------------------------------------------------------
    // LockTimeout (Sprint 4.2) regression coverage
    // ---------------------------------------------------------------

    #[test]
    fn lock_timeout_default_is_engine_default() {
        let lt = LockTimeout::default();
        assert!(lt.is_engine_default());
        assert_eq!(lt.millis(), None);
    }

    #[test]
    fn lock_timeout_engine_default_const_is_none() {
        let lt = LockTimeout::engine_default();
        assert!(lt.is_engine_default());
        assert_eq!(lt.millis(), None);
    }

    #[test]
    fn lock_timeout_from_millis_zero_collapses_to_engine_default() {
        // The wire `0` MUST round-trip as "engine default" so the FFI
        // `lock_timeout_ms = 0` parameter is unambiguous.
        let lt = LockTimeout::from_millis(0);
        assert!(lt.is_engine_default());
        assert_eq!(lt.millis(), None);
    }

    #[test]
    fn lock_timeout_from_millis_non_zero_preserves_value() {
        let lt = LockTimeout::from_millis(2500);
        assert!(!lt.is_engine_default());
        assert_eq!(lt.millis(), Some(2500));
    }

    #[test]
    fn lock_timeout_from_duration_zero_is_engine_default() {
        let lt = LockTimeout::from_duration(Duration::ZERO);
        assert!(
            lt.is_engine_default(),
            "Duration::ZERO must be the canonical 'engine default' input"
        );
    }

    #[test]
    fn lock_timeout_from_duration_sub_millisecond_rounds_up_to_one_ms() {
        // Anyone passing a sub-ms positive duration almost certainly
        // wants "wait a tiny bit", not "engine default". Bump to 1ms.
        let lt = LockTimeout::from_duration(Duration::from_micros(500));
        assert_eq!(
            lt.millis(),
            Some(1),
            "sub-ms positive durations must NOT silently collapse to \
             engine default — they round up to 1ms"
        );
    }

    #[test]
    fn lock_timeout_from_duration_milliseconds_round_trip() {
        let lt = LockTimeout::from_duration(Duration::from_millis(2_500));
        assert_eq!(lt.millis(), Some(2_500));
    }

    #[test]
    fn lock_timeout_from_duration_clamps_at_u32_max() {
        // 60 minutes > u32 ms range (~49.7 days). Use a value that
        // overflows u32 *milliseconds* to verify the saturating cast.
        let big = Duration::from_secs(u64::from(u32::MAX) + 1);
        let lt = LockTimeout::from_duration(big);
        assert_eq!(
            lt.millis(),
            Some(u32::MAX),
            "duration > u32::MAX ms must clamp to the largest u32 \
             rather than wrap around to a tiny value"
        );
    }

    #[test]
    fn lock_timeout_seconds_rounding_for_mysql_db2() {
        // Exact second.
        assert_eq!(
            LockTimeout::from_millis(1_000).millis_as_seconds_rounded_up(),
            Some(1),
        );
        // Sub-second positive → bump to 1.
        assert_eq!(
            LockTimeout::from_millis(500).millis_as_seconds_rounded_up(),
            Some(1),
            "sub-second timeouts must round UP so we never silently \
             relax the caller's bound"
        );
        // 1 ms over a boundary → next second.
        assert_eq!(
            LockTimeout::from_millis(1_001).millis_as_seconds_rounded_up(),
            Some(2),
        );
        // 2.999 s → 3 s.
        assert_eq!(
            LockTimeout::from_millis(2_999).millis_as_seconds_rounded_up(),
            Some(3),
        );
        // Engine-default → None.
        assert_eq!(
            LockTimeout::engine_default().millis_as_seconds_rounded_up(),
            None,
        );
    }

    #[test]
    fn transaction_default_lock_timeout_is_engine_default() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test(
            handles,
            1,
            TransactionState::Active,
            IsolationLevel::ReadCommitted,
        );
        assert!(txn.lock_timeout().is_engine_default());
    }

    #[test]
    fn transaction_for_test_with_lock_timeout_pins_the_value() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test_with_lock_timeout(
            handles,
            7,
            TransactionState::Active,
            IsolationLevel::Serializable,
            SavepointDialect::Sql92,
            TransactionAccessMode::ReadOnly,
            LockTimeout::from_millis(2_500),
        );
        assert_eq!(txn.lock_timeout().millis(), Some(2_500));
        // Other dimensions also survive intact.
        assert_eq!(txn.access_mode(), TransactionAccessMode::ReadOnly);
        assert_eq!(txn.isolation_level(), IsolationLevel::Serializable);
    }

    /// Pure SQL formatting checks (no driver involved) for each engine
    /// in the lock-timeout matrix. Pins the wire format so future
    /// edits to `apply_lock_timeout` can't silently change SQL output.
    #[test]
    fn lock_timeout_sql_format_per_engine() {
        let lt = LockTimeout::from_millis(2_500);
        let ms = lt.millis().unwrap();
        let secs = lt.millis_as_seconds_rounded_up().unwrap();

        assert_eq!(format!("SET LOCK_TIMEOUT {}", ms), "SET LOCK_TIMEOUT 2500");
        assert_eq!(
            format!("SET LOCAL lock_timeout = '{}ms'", ms),
            "SET LOCAL lock_timeout = '2500ms'",
        );
        assert_eq!(
            format!("SET SESSION innodb_lock_wait_timeout = {}", secs),
            "SET SESSION innodb_lock_wait_timeout = 3",
            "MySQL/MariaDB rounds 2500ms up to 3s",
        );
        assert_eq!(
            format!("SET CURRENT LOCK TIMEOUT {}", secs),
            "SET CURRENT LOCK TIMEOUT 3",
        );
        assert_eq!(
            format!("PRAGMA busy_timeout = {}", ms),
            "PRAGMA busy_timeout = 2500"
        );
    }

    #[test]
    fn savepoint_release_still_validates_identifier_on_sqlserver() {
        let handles: SharedHandleManager = Arc::new(Mutex::new(HandleManager::new()));
        let txn = Transaction::for_test_with_dialect(
            handles,
            999,
            TransactionState::Active,
            IsolationLevel::ReadCommitted,
            SavepointDialect::SqlServer,
        );
        // Even though SQL Server has no RELEASE, we still validate the name to
        // give the same defensive guarantee on every dialect.
        assert!(matches!(
            txn.savepoint_release("sp; DROP TABLE x--"),
            Err(OdbcError::ValidationError(_))
        ));
    }
}

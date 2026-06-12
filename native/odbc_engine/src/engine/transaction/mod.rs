mod dialect_sql;
mod lifecycle;
mod savepoint;
mod test_helpers;

#[cfg(test)]
pub(crate) use savepoint::quoting_for;
pub(crate) use savepoint::resolve_savepoint_dialect_for_engine;
pub use savepoint::{Savepoint, SavepointDialect};

use crate::engine::core::{ENGINE_SQLSERVER, ENGINE_UNKNOWN};
use crate::engine::dbms_info::DbmsInfo;
use crate::error::{OdbcError, Result};
use crate::handles::SharedHandleManager;
use crate::pool::SharedPooledConnection;
use std::sync::{Arc, Mutex};

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
/// [`dialect_sql::apply_lock_timeout`].
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
    pub fn from_duration(dur: std::time::Duration) -> Self {
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
    pub(crate) fn with_connection<F, T>(&self, conn_id: u32, op: &str, f: F) -> Result<T>
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

    pub(crate) fn with_connection_mut<F, T>(&self, conn_id: u32, op: &str, f: F) -> Result<T>
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

    pub(crate) fn detect_engine_and_dialect(
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

    pub(crate) fn handles(&self) -> Option<SharedHandleManager> {
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

#[cfg(test)]
mod tests;

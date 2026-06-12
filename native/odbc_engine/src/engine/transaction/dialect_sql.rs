//! Vendor-aware SQL builders for transaction session attributes.
//!
//! Isolation level, access mode (`READ ONLY` / `READ WRITE`), and lock-timeout
//! overrides use different syntax per engine. This module centralises the
//! string generation; [`super::Transaction`] executes the returned statements.

use super::{IsolationLevel, LockTimeout, TransactionAccessMode};
use crate::engine::core::{
    ENGINE_DB2, ENGINE_MARIADB, ENGINE_MYSQL, ENGINE_ORACLE, ENGINE_POSTGRES, ENGINE_SNOWFLAKE,
    ENGINE_SQLITE, ENGINE_SQLSERVER,
};
use crate::error::{OdbcError, Result};

/// Strategy for applying `IsolationLevel` to a connection across vendors.
#[derive(Debug, Clone, Copy)]
pub(crate) enum IsolationStrategy {
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
    pub(crate) fn for_engine(engine: &str) -> Self {
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

/// Outcome of building an isolation-level statement for a given engine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum IsolationSql {
    /// Execute this statement before `set_autocommit(false)`.
    Execute(String),
    /// Engine ignores per-transaction isolation; caller should log and skip.
    Skip {
        engine_id: String,
        level: IsolationLevel,
    },
}

/// Build the isolation-level SQL (or skip marker) for `engine_id`.
pub(crate) fn build_isolation_sql(engine_id: &str, level: IsolationLevel) -> Result<IsolationSql> {
    let strategy = IsolationStrategy::for_engine(engine_id);
    match strategy {
        IsolationStrategy::Sql92 => Ok(IsolationSql::Execute(format!(
            "SET TRANSACTION ISOLATION LEVEL {}",
            level.to_sql_keyword()
        ))),
        IsolationStrategy::SqlitePragma => {
            // SQLite only distinguishes Serializable (default) from Read
            // Uncommitted (shared-cache only). Other levels are no-ops on
            // the safe side.
            let sql = match level {
                IsolationLevel::ReadUncommitted => "PRAGMA read_uncommitted = 1",
                _ => "PRAGMA read_uncommitted = 0",
            };
            Ok(IsolationSql::Execute(sql.to_string()))
        }
        IsolationStrategy::Db2SetCurrent => Ok(IsolationSql::Execute(format!(
            "SET CURRENT ISOLATION = {}",
            level.to_db2_keyword()
        ))),
        IsolationStrategy::OracleRestricted => match level {
            IsolationLevel::ReadCommitted => Ok(IsolationSql::Execute(
                "SET TRANSACTION ISOLATION LEVEL READ COMMITTED".to_string(),
            )),
            IsolationLevel::Serializable => Ok(IsolationSql::Execute(
                "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE".to_string(),
            )),
            IsolationLevel::ReadUncommitted | IsolationLevel::RepeatableRead => {
                Err(OdbcError::ValidationError(format!(
                    "Oracle does not support isolation level {level:?}; \
                     only ReadCommitted and Serializable are supported"
                )))
            }
        },
        IsolationStrategy::Skip => Ok(IsolationSql::Skip {
            engine_id: engine_id.to_string(),
            level,
        }),
    }
}

/// Build `SET TRANSACTION READ ONLY` when the engine supports it.
///
/// `READ WRITE` is the universal default; returns `None` when no SET is needed.
pub(crate) fn build_access_mode_sql(
    engine_id: &str,
    access_mode: TransactionAccessMode,
) -> Option<String> {
    if !access_mode.is_read_only() {
        return None;
    }

    match engine_id {
        ENGINE_POSTGRES | ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 | ENGINE_ORACLE => {
            Some(format!("SET TRANSACTION {}", access_mode.to_sql_keyword()))
        }
        _ => None,
    }
}

/// Returns `true` when the engine has no portable `READ ONLY` hint and the
/// caller should log + skip.
pub(crate) fn access_mode_is_unsupported_noop(engine_id: &str) -> bool {
    !matches!(
        engine_id,
        ENGINE_POSTGRES | ENGINE_MYSQL | ENGINE_MARIADB | ENGINE_DB2 | ENGINE_ORACLE
    )
}

/// Build lock-timeout SQL for `engine_id`, or `None` when the override should
/// be skipped (engine default, unsupported engine, or deliberate no-op).
pub(crate) fn build_lock_timeout_sql(
    engine_id: &str,
    lock_timeout: LockTimeout,
) -> Result<Option<String>> {
    if lock_timeout.is_engine_default() {
        return Ok(None);
    }
    let ms = match lock_timeout.millis() {
        Some(ms) => ms,
        None => {
            return Err(OdbcError::InternalError(
                "build_lock_timeout_sql: LockTimeout invariant violated".to_string(),
            ));
        }
    };

    let sql = match engine_id {
        ENGINE_SQLSERVER => Some(format!("SET LOCK_TIMEOUT {}", ms)),
        ENGINE_POSTGRES => Some(format!("SET LOCAL lock_timeout = '{}ms'", ms)),
        ENGINE_MYSQL | ENGINE_MARIADB => {
            let secs = lock_timeout.millis_as_seconds_rounded_up().ok_or_else(|| {
                OdbcError::InternalError(
                    "build_lock_timeout_sql: millis_as_seconds_rounded_up returned None \
                     for a non-default LockTimeout"
                        .to_string(),
                )
            })?;
            Some(format!("SET SESSION innodb_lock_wait_timeout = {}", secs))
        }
        ENGINE_DB2 => {
            let secs = lock_timeout.millis_as_seconds_rounded_up().ok_or_else(|| {
                OdbcError::InternalError(
                    "build_lock_timeout_sql: millis_as_seconds_rounded_up returned None \
                     for a non-default LockTimeout"
                        .to_string(),
                )
            })?;
            Some(format!("SET CURRENT LOCK TIMEOUT {}", secs))
        }
        ENGINE_SQLITE => Some(format!("PRAGMA busy_timeout = {}", ms)),
        ENGINE_ORACLE | ENGINE_SNOWFLAKE => None,
        _ => None,
    };
    Ok(sql)
}

/// Returns `true` when a lock-timeout request was skipped because the engine
/// has no per-transaction hint (caller should log at debug).
pub(crate) fn lock_timeout_is_unsupported_skip(engine_id: &str) -> bool {
    matches!(engine_id, ENGINE_ORACLE | ENGINE_SNOWFLAKE)
        || !matches!(
            engine_id,
            ENGINE_SQLSERVER
                | ENGINE_POSTGRES
                | ENGINE_MYSQL
                | ENGINE_MARIADB
                | ENGINE_DB2
                | ENGINE_SQLITE
        )
}

impl IsolationLevel {
    /// DB2-style keyword for `SET CURRENT ISOLATION = <X>`.
    pub(crate) fn to_db2_keyword(self) -> &'static str {
        match self {
            Self::ReadUncommitted => "UR", // Uncommitted Read
            Self::ReadCommitted => "CS",   // Cursor Stability
            Self::RepeatableRead => "RS",  // Read Stability
            Self::Serializable => "RR",    // Repeatable Read (DB2 semantics)
        }
    }
}

/// Vendor-aware isolation-level setter.
pub(crate) fn apply_isolation(
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
pub(crate) fn apply_access_mode(
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
pub(crate) fn apply_lock_timeout(
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

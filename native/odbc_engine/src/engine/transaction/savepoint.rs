use crate::engine::core::ENGINE_SQLSERVER;
use crate::engine::identifier::IdentifierQuoting;
use crate::error::Result;

use super::Transaction;

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

/// Resolve `SavepointDialect::Auto` to a concrete dialect using the live DBMS
/// info. SqlServer → `SqlServer`; everything else (including Unknown) → `Sql92`.
pub(crate) fn resolve_savepoint_dialect_for_engine(engine: &str) -> SavepointDialect {
    if engine == ENGINE_SQLSERVER {
        SavepointDialect::SqlServer
    } else {
        SavepointDialect::Sql92
    }
}

/// Choose the appropriate identifier quoting style for a savepoint dialect.
pub(crate) fn quoting_for(dialect: SavepointDialect) -> IdentifierQuoting {
    match dialect {
        // `Auto` should be resolved before reaching this point; default to
        // SQL-92 quoting if it ever leaks through.
        SavepointDialect::Sql92 | SavepointDialect::Auto => IdentifierQuoting::DoubleQuote,
        SavepointDialect::SqlServer => IdentifierQuoting::Brackets,
    }
}

pub struct Savepoint<'t> {
    transaction: &'t Transaction,
    name: String,
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

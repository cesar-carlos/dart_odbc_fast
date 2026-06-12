use crate::engine::core::ENGINE_SQLSERVER;
use crate::engine::identifier::{quote_identifier, validate_identifier, IdentifierQuoting};
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

impl Transaction {
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
}

use crate::error::{OdbcError, Result};
use crate::handles::SharedHandleManager;
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IsolationLevel {
    ReadUncommitted,
    ReadCommitted,
    RepeatableRead,
    Serializable,
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

/// Savepoint SQL dialect. SQL Server uses SAVE TRANSACTION / ROLLBACK TRANSACTION;
/// SQL-92 (PostgreSQL, MySQL, etc.) uses SAVEPOINT / ROLLBACK TO SAVEPOINT.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SavepointDialect {
    /// SAVEPOINT, ROLLBACK TO SAVEPOINT, RELEASE SAVEPOINT (PostgreSQL, MySQL, etc.)
    Sql92,
    /// SAVE TRANSACTION, ROLLBACK TRANSACTION (SQL Server; no RELEASE)
    SqlServer,
}

impl SavepointDialect {
    pub fn from_u32(v: u32) -> Self {
        match v {
            1 => Self::SqlServer,
            _ => Self::Sql92,
        }
    }
}

pub struct Transaction {
    handles: SharedHandleManager,
    conn_id: u32,
    state: Arc<Mutex<TransactionState>>,
    isolation_level: IsolationLevel,
    savepoint_dialect: SavepointDialect,
}

impl Transaction {
    pub fn begin(
        handles: SharedHandleManager,
        conn_id: u32,
        isolation_level: IsolationLevel,
    ) -> Result<Self> {
        Self::begin_with_dialect(handles, conn_id, isolation_level, SavepointDialect::Sql92)
    }

    pub fn begin_with_dialect(
        handles: SharedHandleManager,
        conn_id: u32,
        isolation_level: IsolationLevel,
        savepoint_dialect: SavepointDialect,
    ) -> Result<Self> {
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

        // Apply isolation level via SQL (SET TRANSACTION ISOLATION LEVEL). odbc-api does not
        // expose SQL_ATTR_TXN_ISOLATION; we use SQL-92 syntax supported by SQL Server, PostgreSQL,
        // etc. Drivers that lack support will error here. Must run before set_autocommit(false).
        let sql = format!(
            "SET TRANSACTION ISOLATION LEVEL {}",
            isolation_level.to_sql_keyword()
        );
        conn.connection()
            .execute(&sql, (), None)
            .map(|_| ())
            .map_err(OdbcError::from)?;

        conn.connection_mut()
            .set_autocommit(false)
            .map_err(OdbcError::from)?;

        Ok(Self {
            handles,
            conn_id,
            state,
            isolation_level,
            savepoint_dialect,
        })
    }

    pub fn savepoint_dialect(&self) -> SavepointDialect {
        self.savepoint_dialect
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
        conn.connection_mut().commit().map_err(OdbcError::from)?;
        conn.connection_mut()
            .set_autocommit(true)
            .map_err(OdbcError::from)?;

        *s = TransactionState::Committed;
        Ok(())
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
        conn.connection_mut().rollback().map_err(OdbcError::from)?;
        conn.connection_mut()
            .set_autocommit(true)
            .map_err(OdbcError::from)?;

        *s = TransactionState::RolledBack;
        Ok(())
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
        Self::execute_with_dialect(handles, conn_id, isolation, SavepointDialect::Sql92, f)
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
        let txn = Self::begin_with_dialect(handles.clone(), conn_id, isolation, savepoint_dialect)?;
        match f(&txn) {
            Ok(result) => {
                txn.commit()?;
                Ok(result)
            }
            Err(e) => {
                let _ = txn.rollback();
                Err(e)
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

    #[cfg(test)]
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
        if s == TransactionState::Active {
            log::warn!("Transaction dropped without commit - auto-rollback");
            if let Ok(h) = self.handles.lock() {
                if let Ok(conn_arc) = h.get_connection(self.conn_id) {
                    if let Ok(mut conn) = conn_arc.lock() {
                        let _ = conn.connection_mut().rollback();
                        let _ = conn.connection_mut().set_autocommit(true);
                    }
                }
            }
        }
    }
}

pub struct Savepoint<'t> {
    transaction: &'t Transaction,
    name: String,
}

impl<'t> Savepoint<'t> {
    pub fn create(transaction: &'t Transaction, name: &str) -> Result<Self> {
        let sql = match transaction.savepoint_dialect() {
            SavepointDialect::Sql92 => format!("SAVEPOINT {}", name),
            SavepointDialect::SqlServer => format!("SAVE TRANSACTION {}", name),
        };
        transaction.execute_sql(&sql)?;
        Ok(Self {
            transaction,
            name: name.to_string(),
        })
    }

    pub fn rollback_to(&self) -> Result<()> {
        let sql = match self.transaction.savepoint_dialect() {
            SavepointDialect::Sql92 => format!("ROLLBACK TO SAVEPOINT {}", self.name),
            SavepointDialect::SqlServer => format!("ROLLBACK TRANSACTION {}", self.name),
        };
        self.transaction.execute_sql(&sql)
    }

    pub fn release(self) -> Result<()> {
        match self.transaction.savepoint_dialect() {
            SavepointDialect::Sql92 => {
                let sql = format!("RELEASE SAVEPOINT {}", self.name);
                self.transaction.execute_sql(&sql)
            }
            SavepointDialect::SqlServer => {
                // SQL Server has no RELEASE SAVEPOINT; savepoint is released on commit/rollback
                Ok(())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{IsolationLevel, SavepointDialect, Transaction, TransactionState};
    use crate::error::OdbcError;
    use crate::handles::{HandleManager, SharedHandleManager};
    use std::sync::{Arc, Mutex};

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
    fn savepoint_dialect_from_u32_sql92_default() {
        assert_eq!(SavepointDialect::from_u32(0), SavepointDialect::Sql92);
        assert_eq!(SavepointDialect::from_u32(99), SavepointDialect::Sql92);
    }

    #[test]
    fn savepoint_dialect_from_u32_sqlserver() {
        assert_eq!(SavepointDialect::from_u32(1), SavepointDialect::SqlServer);
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
}

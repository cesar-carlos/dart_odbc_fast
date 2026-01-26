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

pub struct Transaction {
    handles: SharedHandleManager,
    conn_id: u32,
    state: Arc<Mutex<TransactionState>>,
    isolation_level: IsolationLevel,
}

impl Transaction {
    pub fn begin(
        handles: SharedHandleManager,
        conn_id: u32,
        isolation_level: IsolationLevel,
    ) -> Result<Self> {
        let state = Arc::new(Mutex::new(TransactionState::Active));
        let h = handles
            .lock()
            .map_err(|_| OdbcError::InternalError("Failed to lock handles".to_string()))?;
        let conn = h.get_connection(conn_id)?;

        // Apply isolation level via SQL (SET TRANSACTION ISOLATION LEVEL). odbc-api does not
        // expose SQL_ATTR_TXN_ISOLATION; we use SQL-92 syntax supported by SQL Server, PostgreSQL,
        // etc. Drivers that lack support will error here. Must run before set_autocommit(false).
        let sql = format!(
            "SET TRANSACTION ISOLATION LEVEL {}",
            isolation_level.to_sql_keyword()
        );
        conn.execute(&sql, (), None)
            .map(|_| ())
            .map_err(OdbcError::from)?;

        conn.set_autocommit(false).map_err(OdbcError::from)?;
        drop(h);

        Ok(Self {
            handles,
            conn_id,
            state,
            isolation_level,
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

        let h = self.handles.lock().map_err(|_| {
            OdbcError::InternalError("Failed to lock handles for commit".to_string())
        })?;
        let conn = h.get_connection(self.conn_id)?;
        conn.commit().map_err(OdbcError::from)?;
        conn.set_autocommit(true).map_err(OdbcError::from)?;
        drop(h);

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

        let h = self.handles.lock().map_err(|_| {
            OdbcError::InternalError("Failed to lock handles for rollback".to_string())
        })?;
        let conn = h.get_connection(self.conn_id)?;
        conn.rollback().map_err(OdbcError::from)?;
        conn.set_autocommit(true).map_err(OdbcError::from)?;
        drop(h);

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
        let txn = Self::begin(handles.clone(), conn_id, isolation)?;
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
        let h = self.handles.lock().map_err(|_| {
            OdbcError::InternalError("Failed to lock handles for execute_sql".to_string())
        })?;
        let conn = h.get_connection(self.conn_id)?;
        conn.execute(sql, (), None)
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
                if let Ok(conn) = h.get_connection(self.conn_id) {
                    let _ = conn.rollback();
                    let _ = conn.set_autocommit(true);
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
        let sql = format!("SAVEPOINT {}", name);
        transaction.execute_sql(&sql)?;
        Ok(Self {
            transaction,
            name: name.to_string(),
        })
    }

    pub fn rollback_to(&self) -> Result<()> {
        let sql = format!("ROLLBACK TO SAVEPOINT {}", self.name);
        self.transaction.execute_sql(&sql)
    }

    pub fn release(self) -> Result<()> {
        let sql = format!("RELEASE SAVEPOINT {}", self.name);
        self.transaction.execute_sql(&sql)
    }
}

#[cfg(test)]
mod tests {
    use super::IsolationLevel;

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
}

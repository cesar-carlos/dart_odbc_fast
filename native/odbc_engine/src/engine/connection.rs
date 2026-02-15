use super::transaction::{IsolationLevel, Transaction};
use crate::error::{OdbcError, Result};
use crate::handles::SharedHandleManager;

pub struct OdbcConnection {
    conn_id: u32,
    handles: SharedHandleManager,
}

impl OdbcConnection {
    pub fn new(conn_id: u32, handles: SharedHandleManager) -> Self {
        Self { conn_id, handles }
    }

    pub fn connect(handles: SharedHandleManager, conn_str: &str) -> Result<Self> {
        if conn_str.is_empty() {
            return Err(OdbcError::EmptyConnectionString);
        }

        let conn_id = {
            let mut h = handles.lock().map_err(|_| {
                OdbcError::InternalError("Failed to lock handles mutex".to_string())
            })?;
            h.create_connection(conn_str)?
        };

        Ok(Self::new(conn_id, handles))
    }

    pub fn connect_with_timeout(
        handles: SharedHandleManager,
        conn_str: &str,
        timeout_secs: u32,
    ) -> Result<Self> {
        if conn_str.is_empty() {
            return Err(OdbcError::EmptyConnectionString);
        }

        let conn_id = {
            let mut h = handles.lock().map_err(|_| {
                OdbcError::InternalError("Failed to lock handles mutex".to_string())
            })?;
            h.create_connection_with_timeout(conn_str, timeout_secs)?
        };

        Ok(Self::new(conn_id, handles))
    }

    pub fn disconnect(self) -> Result<()> {
        let mut handles = self
            .handles
            .lock()
            .map_err(|_| OdbcError::InternalError("Failed to lock handles mutex".to_string()))?;
        handles.remove_connection(self.conn_id)
    }

    pub fn get_connection_id(&self) -> u32 {
        self.conn_id
    }

    pub fn get_handles(&self) -> SharedHandleManager {
        self.handles.clone()
    }

    pub fn begin_transaction(&self, isolation_level: IsolationLevel) -> Result<Transaction> {
        Transaction::begin(self.handles.clone(), self.conn_id, isolation_level)
    }

    pub fn with_transaction<F, T>(&self, isolation_level: IsolationLevel, f: F) -> Result<T>
    where
        F: FnOnce(&Transaction) -> Result<T>,
    {
        Transaction::execute(self.handles.clone(), self.conn_id, isolation_level, f)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handles::HandleManager;
    use std::sync::{Arc, Mutex};

    #[test]
    fn test_odbc_connection_new() {
        let handles = Arc::new(Mutex::new(HandleManager::new()));
        let conn = OdbcConnection::new(1, handles.clone());
        assert_eq!(conn.get_connection_id(), 1);
    }

    #[test]
    fn test_odbc_connection_get_connection_id() {
        let handles = Arc::new(Mutex::new(HandleManager::new()));
        let conn = OdbcConnection::new(42, handles.clone());
        assert_eq!(conn.get_connection_id(), 42);
    }

    #[test]
    fn test_odbc_connection_get_handles() {
        let handles = Arc::new(Mutex::new(HandleManager::new()));
        let conn = OdbcConnection::new(1, handles.clone());
        let retrieved_handles = conn.get_handles();
        assert!(Arc::ptr_eq(&handles, &retrieved_handles));
    }

    #[test]
    fn test_odbc_connection_connect_empty_string() {
        let handles = Arc::new(Mutex::new(HandleManager::new()));
        let result = OdbcConnection::connect(handles, "");
        assert!(result.is_err());
        if let Err(OdbcError::EmptyConnectionString) = result {
        } else {
            panic!("Expected EmptyConnectionString error");
        }
    }

    #[test]
    fn test_odbc_connection_connect_with_timeout_empty_string() {
        let handles = Arc::new(Mutex::new(HandleManager::new()));
        let result = OdbcConnection::connect_with_timeout(handles, "", 5);
        assert!(result.is_err());
        if let Err(OdbcError::EmptyConnectionString) = result {
        } else {
            panic!("Expected EmptyConnectionString error");
        }
    }

    #[test]
    fn test_begin_transaction_invalid_conn_id_returns_error() {
        use crate::engine::transaction::IsolationLevel;

        let handles = Arc::new(Mutex::new(HandleManager::new()));
        let conn = OdbcConnection::new(999, handles);
        let result = conn.begin_transaction(IsolationLevel::ReadCommitted);
        assert!(result.is_err());
    }

    #[test]
    fn test_with_transaction_invalid_conn_id_returns_error() {
        use crate::engine::transaction::IsolationLevel;

        let handles = Arc::new(Mutex::new(HandleManager::new()));
        let conn = OdbcConnection::new(999, handles);
        let result = conn.with_transaction(IsolationLevel::ReadCommitted, |_| Ok(42));
        assert!(result.is_err());
    }
}

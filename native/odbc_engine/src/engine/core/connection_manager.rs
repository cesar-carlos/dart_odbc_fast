use crate::error::{OdbcError, Result};
use crate::pool::{ConnectionPool, PoolState};
use std::sync::{Arc, Mutex};

pub struct ConnectionManager {
    pools: Arc<Mutex<std::collections::HashMap<u32, Arc<Mutex<ConnectionPool>>>>>,
    next_pool_id: Arc<Mutex<u32>>,
}

impl ConnectionManager {
    pub fn new() -> Self {
        Self {
            pools: Arc::new(Mutex::new(std::collections::HashMap::new())),
            next_pool_id: Arc::new(Mutex::new(1)),
        }
    }

    pub fn create_pool(&self, connection_string: String, max_size: u32) -> Result<u32> {
        let pool = ConnectionPool::new(&connection_string, max_size)
            .map_err(|e| OdbcError::PoolError(format!("Failed to create pool: {}", e)))?;

        let mut pools = self
            .pools
            .lock()
            .map_err(|_| OdbcError::InternalError("Lock poisoned".to_string()))?;
        let mut next_id = self
            .next_pool_id
            .lock()
            .map_err(|_| OdbcError::InternalError("Lock poisoned".to_string()))?;

        let pool_id = *next_id;
        *next_id += 1;

        pools.insert(pool_id, Arc::new(Mutex::new(pool)));
        Ok(pool_id)
    }

    pub fn get_pool(&self, pool_id: u32) -> Result<Arc<Mutex<ConnectionPool>>> {
        let pools = self
            .pools
            .lock()
            .map_err(|_| OdbcError::InternalError("Lock poisoned".to_string()))?;
        pools
            .get(&pool_id)
            .cloned()
            .ok_or_else(|| OdbcError::PoolError(format!("Pool {} not found", pool_id)))
    }

    pub fn get_pool_state(&self, pool_id: u32) -> Result<PoolState> {
        let pools = self
            .pools
            .lock()
            .map_err(|_| OdbcError::InternalError("Lock poisoned".to_string()))?;
        let pool_arc = pools
            .get(&pool_id)
            .ok_or_else(|| OdbcError::PoolError(format!("Pool {} not found", pool_id)))?;
        let pool = pool_arc
            .lock()
            .map_err(|_| OdbcError::InternalError("Lock poisoned".to_string()))?;
        Ok(pool.state())
    }

    pub fn close_pool(&self, pool_id: u32) -> Result<()> {
        let mut pools = self
            .pools
            .lock()
            .map_err(|_| OdbcError::InternalError("Lock poisoned".to_string()))?;
        pools
            .remove(&pool_id)
            .ok_or_else(|| OdbcError::PoolError(format!("Pool {} not found", pool_id)))?;
        Ok(())
    }
}

impl Default for ConnectionManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_connection_manager_new() {
        let manager = ConnectionManager::new();
        let pools = manager.pools.lock().unwrap();
        assert!(pools.is_empty());

        let next_id = manager.next_pool_id.lock().unwrap();
        assert_eq!(*next_id, 1);
    }

    #[test]
    fn test_connection_manager_default() {
        let manager = ConnectionManager::default();
        let pools = manager.pools.lock().unwrap();
        assert!(pools.is_empty());
    }

    #[test]
    #[ignore]
    fn test_create_pool() {
        let manager = ConnectionManager::new();
        let connection_string = "Driver={SQL Server};Server=localhost;Database=test;";

        let pool_id = manager
            .create_pool(connection_string.to_string(), 10)
            .unwrap();
        assert_eq!(pool_id, 1);

        let pools = manager.pools.lock().unwrap();
        assert_eq!(pools.len(), 1);
        assert!(pools.contains_key(&pool_id));
    }

    #[test]
    #[ignore]
    fn test_create_multiple_pools() {
        let manager = ConnectionManager::new();
        let conn_str1 = "Driver={SQL Server};Server=localhost;Database=test1;";
        let conn_str2 = "Driver={SQL Server};Server=localhost;Database=test2;";

        let pool_id1 = manager.create_pool(conn_str1.to_string(), 10).unwrap();
        let pool_id2 = manager.create_pool(conn_str2.to_string(), 20).unwrap();

        assert_eq!(pool_id1, 1);
        assert_eq!(pool_id2, 2);

        let pools = manager.pools.lock().unwrap();
        assert_eq!(pools.len(), 2);
    }

    #[test]
    #[ignore]
    fn test_get_pool() {
        let manager = ConnectionManager::new();
        let connection_string = "Driver={SQL Server};Server=localhost;Database=test;";

        let pool_id = manager
            .create_pool(connection_string.to_string(), 10)
            .unwrap();

        let pool = manager.get_pool(pool_id).unwrap();
        assert!(Arc::ptr_eq(
            &pool,
            manager.pools.lock().unwrap().get(&pool_id).unwrap()
        ));
    }

    #[test]
    fn test_get_pool_not_found() {
        let manager = ConnectionManager::new();

        let result = manager.get_pool(999);
        assert!(result.is_err());

        if let Err(OdbcError::PoolError(msg)) = result {
            assert!(msg.contains("Pool 999 not found"));
        } else {
            panic!("Expected PoolError");
        }
    }

    #[test]
    #[ignore]
    fn test_get_pool_state() {
        let manager = ConnectionManager::new();
        let connection_string = "Driver={SQL Server};Server=localhost;Database=test;";

        let pool_id = manager
            .create_pool(connection_string.to_string(), 10)
            .unwrap();

        let state = manager.get_pool_state(pool_id).unwrap();
        assert_eq!(state.size, 0);
        assert_eq!(state.idle, 0);
    }

    #[test]
    fn test_get_pool_state_not_found() {
        let manager = ConnectionManager::new();

        let result = manager.get_pool_state(999);
        assert!(result.is_err());

        if let Err(OdbcError::PoolError(msg)) = result {
            assert!(msg.contains("Pool 999 not found"));
        } else {
            panic!("Expected PoolError");
        }
    }

    #[test]
    #[ignore]
    fn test_close_pool() {
        let manager = ConnectionManager::new();
        let connection_string = "Driver={SQL Server};Server=localhost;Database=test;";

        let pool_id = manager
            .create_pool(connection_string.to_string(), 10)
            .unwrap();

        let pools_before = manager.pools.lock().unwrap();
        assert_eq!(pools_before.len(), 1);
        drop(pools_before);

        manager.close_pool(pool_id).unwrap();

        let pools_after = manager.pools.lock().unwrap();
        assert_eq!(pools_after.len(), 0);
        assert!(!pools_after.contains_key(&pool_id));
    }

    #[test]
    fn test_close_pool_not_found() {
        let manager = ConnectionManager::new();

        let result = manager.close_pool(999);
        assert!(result.is_err());

        if let Err(OdbcError::PoolError(msg)) = result {
            assert!(msg.contains("Pool 999 not found"));
        } else {
            panic!("Expected PoolError");
        }
    }

    #[test]
    #[ignore]
    fn test_pool_id_increment() {
        let manager = ConnectionManager::new();
        let conn_str = "Driver={SQL Server};Server=localhost;";

        let pool_id1 = manager.create_pool(conn_str.to_string(), 10).unwrap();
        let pool_id2 = manager.create_pool(conn_str.to_string(), 10).unwrap();
        let pool_id3 = manager.create_pool(conn_str.to_string(), 10).unwrap();

        assert_eq!(pool_id1, 1);
        assert_eq!(pool_id2, 2);
        assert_eq!(pool_id3, 3);
    }
}

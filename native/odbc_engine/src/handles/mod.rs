use crate::error::{OdbcError, Result};
use odbc_api::{Connection, ConnectionOptions, Environment};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// Shared connection handle. Allows releasing the HandleManager lock quickly
/// while holding a per-connection lock for the duration of use.
pub type SharedConnection = Arc<Mutex<Connection<'static>>>;

/// Max attempts when allocating connection ID to avoid collision after wrap-around.
const MAX_CONN_ID_ALLOC_ATTEMPTS: u32 = 1000;

pub struct HandleManager {
    env: Option<&'static Environment>,
    connections: HashMap<u32, SharedConnection>,
    next_conn_id: u32,
}

impl HandleManager {
    pub fn new() -> Self {
        Self {
            env: None,
            connections: HashMap::new(),
            next_conn_id: 1,
        }
    }

    pub fn init_environment(&mut self) -> Result<()> {
        let env = Environment::new()?;

        // INTENTIONAL MEMORY LEAK:
        // We leak the Environment to obtain a 'static reference, which is required
        // by odbc_api's Connection type signature (Connection<'static>).
        // This is acceptable because:
        // 1. The Environment is initialized once per application lifetime
        // 2. It's properly cleaned up on process termination
        // 3. This avoids complex lifetime management with odbc_api's requirements
        //
        // Alternative considered: Using Arc<Environment> would require changes to
        // odbc_api's API or unsafe lifetime extensions, which would be less safe.
        let env_static = Box::leak(Box::new(env));
        self.env = Some(env_static);
        Ok(())
    }

    pub fn create_connection(&mut self, conn_str: &str) -> Result<u32> {
        self.create_connection_with_options(conn_str, ConnectionOptions::default())
    }

    pub fn create_connection_with_timeout(
        &mut self,
        conn_str: &str,
        timeout_secs: u32,
    ) -> Result<u32> {
        let opts = ConnectionOptions {
            login_timeout_sec: Some(timeout_secs),
            ..ConnectionOptions::default()
        };
        self.create_connection_with_options(conn_str, opts)
    }

    fn create_connection_with_options(
        &mut self,
        conn_str: &str,
        opts: ConnectionOptions,
    ) -> Result<u32> {
        let env = self.env.ok_or(OdbcError::EnvironmentNotInitialized)?;

        let connection = env.connect_with_connection_string(conn_str, opts)?;

        let mut conn_id = 0u32;
        for _ in 0..MAX_CONN_ID_ALLOC_ATTEMPTS {
            let candidate = self.next_conn_id;
            self.next_conn_id = self.next_conn_id.wrapping_add(1);
            if candidate != 0 && !self.connections.contains_key(&candidate) {
                conn_id = candidate;
                break;
            }
        }

        if conn_id == 0 {
            return Err(OdbcError::InternalError(
                "Failed to allocate connection ID after max attempts".to_string(),
            ));
        }

        self.connections
            .insert(conn_id, Arc::new(Mutex::new(connection)));
        Ok(conn_id)
    }

    /// Returns a clone of the shared connection. Caller holds the HandleManager
    /// lock only briefly; use the returned Arc's Mutex for the duration of use.
    pub fn get_connection(&self, conn_id: u32) -> Result<SharedConnection> {
        self.connections
            .get(&conn_id)
            .cloned()
            .ok_or(OdbcError::InvalidHandle(conn_id))
    }

    /// Runs a closure with the connection locked. Convenience for callers that
    /// need brief access without managing the lock explicitly.
    pub fn with_connection<F, T>(&self, conn_id: u32, f: F) -> Result<T>
    where
        F: FnOnce(&Connection<'static>) -> Result<T>,
    {
        let conn_arc = self.get_connection(conn_id)?;
        let guard = conn_arc
            .lock()
            .map_err(|_| OdbcError::InternalError("Failed to lock connection".to_string()))?;
        f(&guard)
    }

    pub fn remove_connection(&mut self, conn_id: u32) -> Result<()> {
        self.connections
            .remove(&conn_id)
            .ok_or(OdbcError::InvalidHandle(conn_id))?;
        Ok(())
    }

    pub fn has_environment(&self) -> bool {
        self.env.is_some()
    }
}

pub type SharedHandleManager = Arc<Mutex<HandleManager>>;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_helpers::load_dotenv;

    #[test]
    fn test_handle_manager_new() {
        let manager = HandleManager::new();
        assert!(!manager.has_environment());
        assert_eq!(manager.next_conn_id, 1);
    }

    #[test]
    fn test_handle_manager_has_environment_initial() {
        let manager = HandleManager::new();
        assert!(!manager.has_environment());
    }

    #[test]
    #[ignore]
    fn test_handle_manager_init_environment() {
        let mut manager = HandleManager::new();
        assert!(!manager.has_environment());

        manager
            .init_environment()
            .expect("Failed to initialize environment");
        assert!(manager.has_environment());
    }

    #[test]
    #[ignore]
    fn test_handle_manager_create_connection() {
        load_dotenv();
        let conn_str = std::env::var("ODBC_TEST_DSN")
            .ok()
            .filter(|s| !s.is_empty())
            .expect("ODBC_TEST_DSN not set");

        let mut manager = HandleManager::new();
        manager
            .init_environment()
            .expect("Failed to initialize environment");

        let conn_id = manager
            .create_connection(&conn_str)
            .expect("Failed to create connection");
        assert_eq!(conn_id, 1);

        let conn = manager
            .get_connection(conn_id)
            .expect("Failed to get connection");
        assert!(Arc::ptr_eq(
            &conn,
            &manager.get_connection(conn_id).unwrap()
        ));
    }

    #[test]
    #[ignore]
    fn test_handle_manager_create_multiple_connections() {
        load_dotenv();
        let conn_str = std::env::var("ODBC_TEST_DSN")
            .ok()
            .filter(|s| !s.is_empty())
            .expect("ODBC_TEST_DSN not set");

        let mut manager = HandleManager::new();
        manager
            .init_environment()
            .expect("Failed to initialize environment");

        let conn_id1 = manager
            .create_connection(&conn_str)
            .expect("Failed to create connection 1");
        let conn_id2 = manager
            .create_connection(&conn_str)
            .expect("Failed to create connection 2");

        assert_eq!(conn_id1, 1);
        assert_eq!(conn_id2, 2);

        let conn1 = manager
            .get_connection(conn_id1)
            .expect("Failed to get connection 1");
        let conn2 = manager
            .get_connection(conn_id2)
            .expect("Failed to get connection 2");

        assert!(!Arc::ptr_eq(&conn1, &conn2));
    }

    #[test]
    fn test_handle_manager_get_connection_not_found() {
        let manager = HandleManager::new();
        let result = manager.get_connection(999);
        assert!(result.is_err());
        match result {
            Err(OdbcError::InvalidHandle(999)) => (),
            _ => panic!("Expected InvalidHandle error"),
        }
    }

    #[test]
    #[ignore]
    fn test_handle_manager_remove_connection() {
        load_dotenv();
        let conn_str = std::env::var("ODBC_TEST_DSN")
            .ok()
            .filter(|s| !s.is_empty())
            .expect("ODBC_TEST_DSN not set");

        let mut manager = HandleManager::new();
        manager
            .init_environment()
            .expect("Failed to initialize environment");

        let conn_id = manager
            .create_connection(&conn_str)
            .expect("Failed to create connection");
        assert!(manager.get_connection(conn_id).is_ok());

        manager
            .remove_connection(conn_id)
            .expect("Failed to remove connection");

        let result = manager.get_connection(conn_id);
        assert!(result.is_err());
        match result {
            Err(OdbcError::InvalidHandle(id)) => assert_eq!(id, conn_id),
            _ => panic!("Expected InvalidHandle error"),
        }
    }

    #[test]
    fn test_handle_manager_remove_connection_not_found() {
        let mut manager = HandleManager::new();
        let result = manager.remove_connection(999);
        assert!(result.is_err());
        match result {
            Err(OdbcError::InvalidHandle(999)) => (),
            _ => panic!("Expected InvalidHandle error"),
        }
    }

    #[test]
    fn test_handle_manager_create_connection_without_environment() {
        let mut manager = HandleManager::new();
        let result = manager.create_connection("Driver={SQL Server};Server=localhost;");
        assert!(result.is_err());
        match result {
            Err(OdbcError::EnvironmentNotInitialized) => (),
            _ => panic!("Expected EnvironmentNotInitialized error"),
        }
    }

    #[test]
    fn test_handle_manager_create_connection_with_timeout_without_environment() {
        let mut manager = HandleManager::new();
        let result =
            manager.create_connection_with_timeout("Driver={SQL Server};Server=localhost;", 5);
        assert!(result.is_err());
        match result {
            Err(OdbcError::EnvironmentNotInitialized) => (),
            _ => panic!("Expected EnvironmentNotInitialized error"),
        }
    }

    #[test]
    fn test_connection_id_wrapping() {
        let mut manager = HandleManager::new();
        manager.next_conn_id = u32::MAX;

        assert_eq!(manager.next_conn_id, u32::MAX);

        manager.next_conn_id = manager.next_conn_id.wrapping_add(1);
        assert_eq!(manager.next_conn_id, 0, "ID should wrap to 0");

        manager.next_conn_id = manager.next_conn_id.wrapping_add(1);
        assert_eq!(manager.next_conn_id, 1, "ID should wrap to 1");
    }

    #[test]
    fn test_connection_id_wrapping_behavior() {
        let mut manager = HandleManager::new();

        manager.next_conn_id = 5;

        let candidate1 = manager.next_conn_id;
        manager.next_conn_id = manager.next_conn_id.wrapping_add(1);
        assert_eq!(candidate1, 5);
        assert_eq!(manager.next_conn_id, 6);

        let candidate2 = manager.next_conn_id;
        manager.next_conn_id = manager.next_conn_id.wrapping_add(1);
        assert_eq!(candidate2, 6);
        assert_eq!(manager.next_conn_id, 7);

        manager.next_conn_id = u32::MAX - 1;
        let candidate3 = manager.next_conn_id;
        manager.next_conn_id = manager.next_conn_id.wrapping_add(1);
        assert_eq!(candidate3, u32::MAX - 1);
        assert_eq!(manager.next_conn_id, u32::MAX);

        let candidate4 = manager.next_conn_id;
        manager.next_conn_id = manager.next_conn_id.wrapping_add(1);
        assert_eq!(candidate4, u32::MAX);
        assert_eq!(manager.next_conn_id, 0);
    }
}

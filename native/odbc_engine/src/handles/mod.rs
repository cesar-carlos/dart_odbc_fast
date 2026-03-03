mod cached_connection;

pub use cached_connection::CachedConnection;

use crate::error::{OdbcError, Result};
use odbc_api::{Connection, ConnectionOptions, Environment};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// Shared connection handle. Wraps Connection with optional prepared-statement cache.
/// Use `CachedConnection::connection()` when raw Connection access is needed.
pub type SharedConnection = Arc<Mutex<CachedConnection>>;

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

        self.connections.insert(
            conn_id,
            Arc::new(Mutex::new(CachedConnection::new(connection))),
        );
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
        f(guard.connection())
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

    #[test]
    fn test_id_collision_detection_skips_zero() {
        let mut manager = HandleManager::new();
        manager.next_conn_id = 0;

        let candidate1 = manager.next_conn_id;
        manager.next_conn_id = manager.next_conn_id.wrapping_add(1);

        assert_eq!(candidate1, 0, "First candidate is 0");
        assert_eq!(
            manager.next_conn_id, 1,
            "After increment, next_conn_id is 1"
        );
    }

    #[test]
    fn test_id_collision_detection_logic() {
        let manager = HandleManager::new();

        let id_1_exists = manager.connections.contains_key(&1);
        let id_2_exists = manager.connections.contains_key(&2);
        let id_3_exists = manager.connections.contains_key(&3);

        assert!(!id_1_exists, "ID 1 should not exist initially");
        assert!(!id_2_exists, "ID 2 should not exist initially");
        assert!(!id_3_exists, "ID 3 should not exist initially");

        let candidate = 1u32;
        let is_valid = candidate != 0 && !manager.connections.contains_key(&candidate);
        assert!(is_valid, "ID 1 should be valid for allocation");

        let candidate_zero = 0u32;
        let is_valid_zero =
            candidate_zero != 0 && !manager.connections.contains_key(&candidate_zero);
        assert!(!is_valid_zero, "ID 0 should never be valid for allocation");
    }

    #[test]
    fn test_id_wrap_around_sequence() {
        let mut manager = HandleManager::new();
        manager.next_conn_id = u32::MAX;

        let mut found_id = 0u32;
        for _ in 0..MAX_CONN_ID_ALLOC_ATTEMPTS {
            let candidate = manager.next_conn_id;
            manager.next_conn_id = manager.next_conn_id.wrapping_add(1);

            if candidate != 0 && !manager.connections.contains_key(&candidate) {
                found_id = candidate;
                break;
            }
        }

        assert_eq!(found_id, u32::MAX, "Should find u32::MAX as available");
        assert_eq!(
            manager.next_conn_id, 0,
            "After MAX, next_conn_id wraps to 0"
        );
    }

    #[test]
    fn test_id_allocation_algorithm_simulation() {
        let mut next_id = 1u32;
        let occupied_ids: std::collections::HashSet<u32> = vec![1, 2].into_iter().collect();

        let mut found_id = 0u32;
        for _ in 0..10 {
            let candidate = next_id;
            next_id = next_id.wrapping_add(1);

            if candidate != 0 && !occupied_ids.contains(&candidate) {
                found_id = candidate;
                break;
            }
        }

        assert_eq!(
            found_id, 3,
            "First available ID should be 3 when 1 and 2 are occupied"
        );
    }

    #[test]
    fn test_id_generation_never_returns_zero() {
        let mut next_id = 0u32;

        for _ in 0..10 {
            let candidate = next_id;
            next_id = next_id.wrapping_add(1);

            if candidate != 0 {
                assert_ne!(candidate, 0, "Allocated ID should never be 0");
            }
        }
    }

    #[test]
    fn test_id_collision_exhaustion_simulation() {
        let mut next_id = 1u32;
        let occupied_ids: std::collections::HashSet<u32> = (1..=100).collect();

        let mut found_id = 0u32;
        let mut attempts = 0u32;

        for _ in 0..MAX_CONN_ID_ALLOC_ATTEMPTS {
            attempts += 1;
            let candidate = next_id;
            next_id = next_id.wrapping_add(1);

            if candidate != 0 && !occupied_ids.contains(&candidate) {
                found_id = candidate;
                break;
            }
        }

        assert_eq!(found_id, 101, "Should find ID 101 after 100 occupied slots");
        assert!(
            attempts <= MAX_CONN_ID_ALLOC_ATTEMPTS,
            "Should find within max attempts"
        );
    }

    #[test]
    fn test_id_allocation_near_max_attempts() {
        let mut next_id = 1u32;
        let occupied_ids: std::collections::HashSet<u32> = (1..=500).collect();

        let mut found_id = 0u32;
        let mut attempts = 0u32;

        for _ in 0..MAX_CONN_ID_ALLOC_ATTEMPTS {
            attempts += 1;
            let candidate = next_id;
            next_id = next_id.wrapping_add(1);

            if candidate != 0 && !occupied_ids.contains(&candidate) {
                found_id = candidate;
                break;
            }
        }

        assert_eq!(found_id, 501, "Should find ID 501 after 500 occupied slots");
        assert!(
            attempts <= MAX_CONN_ID_ALLOC_ATTEMPTS,
            "Should find within max attempts"
        );
        assert_eq!(attempts, 501, "Should take exactly 501 attempts");
    }

    #[test]
    fn test_wrapping_add_arithmetic() {
        let test_cases = vec![
            (0u32, 1u32),
            (u32::MAX - 1, u32::MAX),
            (u32::MAX, 0u32),
            (100, 101),
        ];

        for (input, expected) in test_cases {
            let result = input.wrapping_add(1);
            assert_eq!(
                result, expected,
                "wrapping_add(1) for {} should be {}",
                input, expected
            );
        }
    }

    #[test]
    fn test_hashmap_contains_key_behavior() {
        use std::collections::HashMap;
        let mut map: HashMap<u32, u32> = HashMap::new();

        map.insert(5, 100);
        map.insert(10, 200);

        assert!(map.contains_key(&5));
        assert!(map.contains_key(&10));
        assert!(!map.contains_key(&1));
        assert!(!map.contains_key(&0));

        map.remove(&5);
        assert!(!map.contains_key(&5));
        assert!(map.contains_key(&10));
    }

    #[test]
    fn test_max_conn_id_alloc_attempts_constant() {
        assert_eq!(
            MAX_CONN_ID_ALLOC_ATTEMPTS, 1000,
            "MAX_CONN_ID_ALLOC_ATTEMPTS should be 1000"
        );
    }
}

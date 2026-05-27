use crate::error::Result;
use crate::handles::{HandleManager, SharedHandleManager};
use std::sync::{Arc, Mutex};

pub struct OdbcEnvironment {
    handles: SharedHandleManager,
}

impl Default for OdbcEnvironment {
    fn default() -> Self {
        Self::new()
    }
}

impl OdbcEnvironment {
    pub fn new() -> Self {
        Self {
            handles: Arc::new(Mutex::new(HandleManager::new())),
        }
    }

    pub fn init(&self) -> Result<()> {
        let mut handles = self.handles.lock().map_err(|_| {
            crate::error::OdbcError::InternalError("Failed to lock handles mutex".to_string())
        })?;
        handles.init_environment()
    }

    pub fn is_initialized(&self) -> bool {
        let handles = self.handles.lock();
        match handles {
            Ok(h) => h.has_environment(),
            Err(_) => false, // If mutex is poisoned, treat as not initialized
        }
    }

    pub fn get_handles(&self) -> SharedHandleManager {
        self.handles.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_should_produce_uninitialized_environment() {
        let env = OdbcEnvironment::new();
        assert!(!env.is_initialized());
    }

    #[test]
    fn default_should_match_new_constructor() {
        let env = OdbcEnvironment::default();
        assert!(!env.is_initialized());
    }

    #[test]
    fn get_handles_should_return_shared_arc_reference() {
        let env = OdbcEnvironment::new();
        let a = env.get_handles();
        let b = env.get_handles();
        // Both references must point to the same underlying mutex.
        assert!(Arc::ptr_eq(&a, &b));
    }

    #[test]
    fn is_initialized_should_return_false_until_init_succeeds() {
        let env = OdbcEnvironment::new();
        assert!(!env.is_initialized());
        // init() may fail if no ODBC environment is available; ignore the
        // result and verify the bool reflects whatever happened.
        let initialized = env.init().is_ok();
        assert_eq!(env.is_initialized(), initialized);
    }
}

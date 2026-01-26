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

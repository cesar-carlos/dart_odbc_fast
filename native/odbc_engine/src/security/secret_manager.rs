use crate::error::{OdbcError, Result};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use zeroize::ZeroizeOnDrop;

#[derive(ZeroizeOnDrop)]
pub struct Secret {
    value: Vec<u8>,
}

impl Secret {
    pub fn new(value: Vec<u8>) -> Self {
        Self { value }
    }

    pub fn from_string(value: String) -> Self {
        Self::new(value.into_bytes())
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.value
    }

    pub fn to_string_lossy(&self) -> String {
        String::from_utf8_lossy(&self.value).to_string()
    }
}

pub struct SecretManager {
    secrets: Arc<Mutex<HashMap<String, Secret>>>,
}

impl SecretManager {
    pub fn new() -> Self {
        Self {
            secrets: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn store(&self, key: String, value: Secret) -> Result<()> {
        let mut secrets = self
            .secrets
            .lock()
            .map_err(|_| OdbcError::InternalError("Lock poisoned".to_string()))?;
        secrets.insert(key, value);
        Ok(())
    }

    pub fn retrieve(&self, key: &str) -> Result<Secret> {
        let secrets = self
            .secrets
            .lock()
            .map_err(|_| OdbcError::InternalError("Lock poisoned".to_string()))?;
        let secret = secrets
            .get(key)
            .ok_or_else(|| OdbcError::InternalError(format!("Secret not found: {}", key)))?;

        Ok(Secret::new(secret.as_bytes().to_vec()))
    }

    pub fn remove(&self, key: &str) -> Result<()> {
        let mut secrets = self
            .secrets
            .lock()
            .map_err(|_| OdbcError::InternalError("Lock poisoned".to_string()))?;
        secrets.remove(key);
        Ok(())
    }

    pub fn clear(&self) {
        if let Ok(mut secrets) = self.secrets.lock() {
            secrets.clear();
        }
    }
}

impl Default for SecretManager {
    fn default() -> Self {
        Self::new()
    }
}

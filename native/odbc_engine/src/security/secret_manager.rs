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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::OdbcError;

    #[test]
    fn test_secret_new_and_as_bytes() {
        let bytes = vec![1u8, 2, 3];
        let secret = Secret::new(bytes.clone());
        assert_eq!(secret.as_bytes(), &bytes[..]);
    }

    #[test]
    fn test_secret_from_string_and_to_string_lossy() {
        let s = "test_value".to_string();
        let secret = Secret::from_string(s.clone());
        assert_eq!(secret.to_string_lossy(), "test_value");
        assert_eq!(secret.as_bytes(), b"test_value");
    }

    #[test]
    fn test_secret_manager_new_empty_retrieve_fails() {
        let manager = SecretManager::new();
        assert!(manager.retrieve("any").is_err());
    }

    #[test]
    fn test_secret_manager_default() {
        let manager = SecretManager::default();
        assert!(manager.retrieve("any").is_err());
    }

    #[test]
    fn test_secret_manager_store_and_retrieve_success() {
        let manager = SecretManager::new();
        let secret = Secret::from_string("test_value".to_string());
        manager.store("key1".to_string(), secret).unwrap();
        let retrieved = manager.retrieve("key1").unwrap();
        assert_eq!(retrieved.to_string_lossy(), "test_value");
    }

    #[test]
    fn test_secret_manager_retrieve_missing_key_returns_error() {
        let manager = SecretManager::new();
        let result = manager.retrieve("nonexistent");
        match &result {
            Err(OdbcError::InternalError(msg)) => assert!(msg.contains("Secret not found")),
            Err(e) => panic!("expected InternalError, got {:?}", e),
            Ok(_) => panic!("expected Err"),
        }
    }

    #[test]
    fn test_secret_manager_remove() {
        let manager = SecretManager::new();
        manager
            .store("k".to_string(), Secret::from_string("v".to_string()))
            .unwrap();
        manager.remove("k").unwrap();
        assert!(manager.retrieve("k").is_err());
    }

    #[test]
    fn test_secret_manager_clear() {
        let manager = SecretManager::new();
        manager
            .store("a".to_string(), Secret::from_string("x".to_string()))
            .unwrap();
        manager.clear();
        assert!(manager.retrieve("a").is_err());
    }
}

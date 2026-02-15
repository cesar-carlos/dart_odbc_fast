mod async_bridge;
pub mod engine;
mod error;
pub mod ffi;
mod handles;
pub mod observability;
pub mod plugins;
pub mod pool;
pub mod protocol;
pub mod security;
mod versioning;

pub use engine::{
    execute_multi_result, execute_query_with_connection, execute_query_with_params, OdbcConnection,
    OdbcEnvironment,
};
pub use error::{OdbcError, Result};
pub use protocol::{
    decode_multi, deserialize_params, encode_multi, serialize_params, BinaryProtocolDecoder,
    ColumnInfo, DecodedResult, MultiResultItem, ParamValue,
};

#[cfg(feature = "ffi-tests")]
pub use ffi::{
    odbc_connect, odbc_disconnect, odbc_exec_query, odbc_get_error, odbc_init,
    odbc_savepoint_create, odbc_savepoint_release, odbc_savepoint_rollback,
};

#[cfg(feature = "test-helpers")]
pub mod test_helpers {
    use std::sync::Once;

    static INIT: Once = Once::new();

    /// Loads env vars from a `.env` file (once). Overrides existing vars.
    /// Used by lib unit tests and by `tests/helpers/e2e.rs`.
    pub fn load_dotenv() {
        INIT.call_once(|| {
            let mut current = std::env::current_dir().ok();
            let mut found_env = None;

            while let Some(dir) = current {
                let dotenv_path = dir.join(".env");
                if dotenv_path.exists() {
                    found_env = Some(dotenv_path);
                    break;
                }
                if let Some(parent) = dir.parent() {
                    let root_dotenv = parent.join(".env");
                    if root_dotenv.exists() {
                        found_env = Some(root_dotenv);
                        break;
                    }
                }
                current = dir.parent().map(|p| p.to_path_buf());
                if dir.components().count() < 3 {
                    break;
                }
            }

            if let Some(env_path) = found_env {
                if let Ok(contents) = std::fs::read_to_string(&env_path) {
                    for line in contents.lines() {
                        let line = line.trim();
                        if line.is_empty() || line.starts_with('#') {
                            continue;
                        }
                        if let Some(equal_pos) = line.find('=') {
                            let key = line[..equal_pos].trim();
                            let value = line[equal_pos + 1..].trim();
                            let value = value.trim_matches('"').trim_matches('\'');
                            std::env::set_var(key, value);
                        }
                    }
                    eprintln!("Loaded .env from: {}", env_path.display());
                }
            } else {
                let _ = dotenvy::dotenv();
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn test_environment_creation() {
        let env = OdbcEnvironment::new();
        assert!(!env.is_initialized());
    }

    #[test]
    fn test_environment_handles() {
        let env = OdbcEnvironment::new();
        let handles = env.get_handles();
        assert!(Arc::ptr_eq(&env.get_handles(), &handles));
    }

    #[test]
    fn test_connection_empty_string() {
        let env = OdbcEnvironment::new();
        let handles = env.get_handles();

        let result = OdbcConnection::connect(handles, "");
        assert!(result.is_err());
        match result {
            Err(OdbcError::EmptyConnectionString) => (),
            _ => panic!("Expected EmptyConnectionString error"),
        }
    }

    #[test]
    fn test_load_dotenv_invokes_once() {
        crate::test_helpers::load_dotenv();
    }

    #[test]
    fn test_load_dotenv_idempotent() {
        crate::test_helpers::load_dotenv();
        crate::test_helpers::load_dotenv();
    }
}

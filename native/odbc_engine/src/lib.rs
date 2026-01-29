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
}

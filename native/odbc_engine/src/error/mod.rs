use odbc_api::handles::Record as OdbcRecord;
use thiserror::Error;

/// Error category for decision-making (retry, abort, reconnect, etc.)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCategory {
    /// Transient error - retry may resolve
    Transient,
    /// Fatal error - should abort operation
    Fatal,
    /// Validation error - invalid user input
    Validation,
    /// Connection lost - should reconnect
    ConnectionLost,
}

#[derive(Error, Debug, Clone)]
pub enum OdbcError {
    #[error("ODBC error: {0}")]
    OdbcApi(String),

    #[error("Invalid handle ID: {0}")]
    InvalidHandle(u32),

    #[error("Connection string is empty")]
    EmptyConnectionString,

    #[error("Environment not initialized")]
    EnvironmentNotInitialized,

    #[error("Structured error: {message}")]
    Structured {
        sqlstate: [u8; 5],
        native_code: i32,
        message: String,
    },

    #[error("Pool error: {0}")]
    PoolError(String),

    #[error("Internal error: {0}")]
    InternalError(String),

    #[error("Validation error: {0}")]
    ValidationError(String),

    #[error("Unsupported feature: {0}")]
    UnsupportedFeature(String),
}

impl From<odbc_api::Error> for OdbcError {
    fn from(err: odbc_api::Error) -> Self {
        if let Some(structured) = try_extract_structured(&err) {
            return structured;
        }
        OdbcError::OdbcApi(err.to_string())
    }
}

fn try_extract_structured(err: &odbc_api::Error) -> Option<OdbcError> {
    use odbc_api::Error as OdbcErr;
    let record = match err {
        OdbcErr::Diagnostics { record, .. } => record,
        OdbcErr::UnsupportedOdbcApiVersion(record) => record,
        OdbcErr::InvalidRowArraySize { record, .. } => record,
        OdbcErr::UnableToRepresentNull(record) => record,
        OdbcErr::OracleOdbcDriverDoesNotSupport64Bit(record) => record,
        _ => return None,
    };
    Some(structured_from_odbc_record(record))
}

fn structured_from_odbc_record(record: &OdbcRecord) -> OdbcError {
    let sqlstate = record.state.0;
    let native_code = record.native_error;
    let message = record.to_string();
    OdbcError::Structured {
        sqlstate,
        native_code,
        message,
    }
}

impl OdbcError {
    pub fn sqlstate(&self) -> [u8; 5] {
        match self {
            OdbcError::Structured { sqlstate, .. } => *sqlstate,
            _ => [0u8; 5],
        }
    }

    pub fn native_code(&self) -> i32 {
        match self {
            OdbcError::Structured { native_code, .. } => *native_code,
            _ => 0,
        }
    }

    pub fn message(&self) -> String {
        match self {
            OdbcError::Structured { message, .. } => message.clone(),
            _ => self.to_string(),
        }
    }

    pub fn to_structured(&self) -> StructuredError {
        StructuredError {
            sqlstate: self.sqlstate(),
            native_code: self.native_code(),
            message: self.message(),
        }
    }

    /// Returns true if the error is transient and may be retried
    pub fn is_retryable(&self) -> bool {
        match self {
            OdbcError::Structured { sqlstate, .. } => {
                // Connection errors (08xxx) are often retryable
                sqlstate[0] == b'0' && sqlstate[1] == b'8'
            }
            OdbcError::PoolError(_) => true,
            OdbcError::InternalError(msg) => {
                // Some internal errors like timeouts are retryable
                msg.contains("timeout") || msg.contains("Timeout")
            }
            _ => false,
        }
    }

    /// Returns true if this is a connection-related error
    pub fn is_connection_error(&self) -> bool {
        match self {
            OdbcError::EmptyConnectionString | OdbcError::EnvironmentNotInitialized => true,
            OdbcError::Structured { sqlstate, .. } => sqlstate[0] == b'0' && sqlstate[1] == b'8',
            _ => false,
        }
    }

    /// Returns the error category for decision-making
    pub fn error_category(&self) -> ErrorCategory {
        if matches!(self, OdbcError::ValidationError(_)) {
            return ErrorCategory::Validation;
        }
        if matches!(self, OdbcError::UnsupportedFeature(_)) {
            return ErrorCategory::Fatal;
        }
        if self.is_connection_error() {
            return ErrorCategory::ConnectionLost;
        }
        if self.is_retryable() {
            return ErrorCategory::Transient;
        }
        ErrorCategory::Fatal
    }
}

#[derive(Debug, Clone)]
pub struct StructuredError {
    pub sqlstate: [u8; 5],
    pub native_code: i32,
    pub message: String,
}

impl StructuredError {
    pub fn serialize(&self) -> Vec<u8> {
        let mut buffer = Vec::new();
        buffer.extend_from_slice(&self.sqlstate);
        buffer.extend_from_slice(&self.native_code.to_le_bytes());
        let msg_bytes = self.message.as_bytes();
        buffer.extend_from_slice(&(msg_bytes.len() as u32).to_le_bytes());
        buffer.extend_from_slice(msg_bytes);
        buffer
    }

    pub fn deserialize(data: &[u8]) -> Option<Self> {
        if data.len() < 13 {
            return None;
        }

        let mut sqlstate = [0u8; 5];
        sqlstate.copy_from_slice(&data[0..5]);

        let native_code = i32::from_le_bytes([data[5], data[6], data[7], data[8]]);

        let msg_len = u32::from_le_bytes([data[9], data[10], data[11], data[12]]) as usize;

        if data.len() < 13 + msg_len {
            return None;
        }

        let message = String::from_utf8(data[13..13 + msg_len].to_vec()).ok()?;

        Some(Self {
            sqlstate,
            native_code,
            message,
        })
    }
}

pub type Result<T> = std::result::Result<T, OdbcError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_odbc_error_variants() {
        let err1 = OdbcError::EmptyConnectionString;
        assert_eq!(err1.to_string(), "Connection string is empty");

        let err2 = OdbcError::InvalidHandle(42);
        assert_eq!(err2.to_string(), "Invalid handle ID: 42");

        let err3 = OdbcError::EnvironmentNotInitialized;
        assert_eq!(err3.to_string(), "Environment not initialized");

        let err4 = OdbcError::ValidationError("Test validation".to_string());
        assert_eq!(err4.to_string(), "Validation error: Test validation");

        let err5 = OdbcError::OdbcApi("Driver error".to_string());
        assert!(err5.to_string().contains("Driver error"));

        let err6 = OdbcError::PoolError("Pool exhausted".to_string());
        assert!(err6.to_string().contains("Pool exhausted"));

        let err7 = OdbcError::InternalError("Lock poisoned".to_string());
        assert!(err7.to_string().contains("Lock poisoned"));

        let err8 = OdbcError::UnsupportedFeature("Feature X".to_string());
        assert!(err8.to_string().contains("Feature X"));
    }

    #[test]
    fn test_structured_error_properties() {
        let err = OdbcError::Structured {
            sqlstate: [b'2', b'3', b'0', b'0', b'0'],
            native_code: 42,
            message: "Test error".to_string(),
        };

        assert_eq!(err.sqlstate(), [b'2', b'3', b'0', b'0', b'0']);
        assert_eq!(err.native_code(), 42);
        assert_eq!(err.message(), "Test error");
    }

    #[test]
    fn test_non_structured_error_defaults() {
        let err = OdbcError::EmptyConnectionString;
        assert_eq!(err.sqlstate(), [0u8; 5]);
        assert_eq!(err.native_code(), 0);
    }

    #[test]
    fn test_non_structured_error_message_returns_display() {
        let err = OdbcError::ValidationError("Bad input".to_string());
        assert_eq!(err.message(), "Validation error: Bad input");
    }

    #[test]
    fn test_error_category_unsupported_feature_is_fatal() {
        let err = OdbcError::UnsupportedFeature("Savepoints".to_string());
        assert_eq!(err.error_category(), ErrorCategory::Fatal);
    }

    #[test]
    fn test_error_category_variants() {
        let _ = ErrorCategory::Transient;
        let _ = ErrorCategory::Fatal;
        let _ = ErrorCategory::Validation;
        let _ = ErrorCategory::ConnectionLost;
    }

    #[test]
    fn test_to_structured() {
        let err = OdbcError::ValidationError("Invalid input".to_string());
        let structured = err.to_structured();

        assert_eq!(structured.sqlstate, [0u8; 5]);
        assert_eq!(structured.native_code, 0);
        assert!(structured.message.contains("Invalid input"));
    }

    #[test]
    fn test_structured_error_serialize() {
        let error = StructuredError {
            sqlstate: [b'2', b'3', b'0', b'0', b'0'],
            native_code: 42,
            message: "Test error".to_string(),
        };

        let serialized = error.serialize();

        // Verify format: [sqlstate: 5][native_code: 4][msg_len: 4][message: N]
        assert_eq!(&serialized[0..5], b"23000");
        assert_eq!(
            i32::from_le_bytes([serialized[5], serialized[6], serialized[7], serialized[8]]),
            42
        );
        let msg_len = u32::from_le_bytes([
            serialized[9],
            serialized[10],
            serialized[11],
            serialized[12],
        ]) as usize;
        assert_eq!(msg_len, "Test error".len());
        assert_eq!(&serialized[13..], b"Test error");
    }

    #[test]
    fn test_structured_error_deserialize() {
        let error = StructuredError {
            sqlstate: [b'2', b'3', b'0', b'0', b'0'],
            native_code: 42,
            message: "Test error".to_string(),
        };

        let serialized = error.serialize();
        let deserialized = StructuredError::deserialize(&serialized).expect("Should deserialize");

        assert_eq!(deserialized.sqlstate, error.sqlstate);
        assert_eq!(deserialized.native_code, error.native_code);
        assert_eq!(deserialized.message, error.message);
    }

    #[test]
    fn test_structured_error_deserialize_invalid_data() {
        // Too short
        let data = vec![1, 2, 3];
        assert!(StructuredError::deserialize(&data).is_none());

        // Header only, no message
        let mut data = vec![0u8; 13];
        data[9..13].copy_from_slice(&10u32.to_le_bytes()); // msg_len = 10, but no data
        assert!(StructuredError::deserialize(&data).is_none());
    }

    #[test]
    fn test_structured_error_roundtrip() {
        let original = StructuredError {
            sqlstate: [b'4', b'2', b'S', b'0', b'2'],
            native_code: -123,
            message: "Connection failed: timeout".to_string(),
        };

        let serialized = original.serialize();
        let deserialized = StructuredError::deserialize(&serialized).expect("Should deserialize");

        assert_eq!(deserialized.sqlstate, original.sqlstate);
        assert_eq!(deserialized.native_code, original.native_code);
        assert_eq!(deserialized.message, original.message);
    }

    #[test]
    fn test_structured_error_empty_message() {
        let error = StructuredError {
            sqlstate: [0u8; 5],
            native_code: 0,
            message: String::new(),
        };

        let serialized = error.serialize();
        let deserialized = StructuredError::deserialize(&serialized).expect("Should deserialize");

        assert_eq!(deserialized.message, "");
    }

    #[test]
    fn test_structured_error_unicode_message() {
        let error = StructuredError {
            sqlstate: [b'2', b'3', b'0', b'0', b'0'],
            native_code: 42,
            message: "Erro em português: €$¥".to_string(),
        };

        let serialized = error.serialize();
        let deserialized = StructuredError::deserialize(&serialized).expect("Should deserialize");

        assert_eq!(deserialized.message, error.message);
    }

    #[test]
    fn test_is_retryable() {
        // Connection errors with SQLSTATE '08xxx' should be retryable
        let conn_error = OdbcError::Structured {
            sqlstate: [b'0', b'8', b'0', b'0', b'1'],
            native_code: 0,
            message: "Connection timeout".to_string(),
        };
        assert!(
            conn_error.is_retryable(),
            "Connection errors should be retryable"
        );

        // Pool errors should be retryable
        let pool_error = OdbcError::PoolError("Pool exhausted".to_string());
        assert!(pool_error.is_retryable(), "Pool errors should be retryable");

        // Internal errors with timeout should be retryable
        let timeout_error = OdbcError::InternalError("Query timeout".to_string());
        assert!(
            timeout_error.is_retryable(),
            "Timeout errors should be retryable"
        );

        let timeout_error2 = OdbcError::InternalError("Operation Timeout".to_string());
        assert!(
            timeout_error2.is_retryable(),
            "Timeout errors should be retryable"
        );

        // Non-retryable errors
        let validation_error = OdbcError::ValidationError("Invalid input".to_string());
        assert!(
            !validation_error.is_retryable(),
            "Validation errors should not be retryable"
        );

        let fatal_error = OdbcError::Structured {
            sqlstate: [b'2', b'3', b'0', b'0', b'0'],
            native_code: 0,
            message: "Constraint violation".to_string(),
        };
        assert!(
            !fatal_error.is_retryable(),
            "Constraint violations should not be retryable"
        );
    }

    #[test]
    fn test_is_connection_error() {
        // EmptyConnectionString should be connection error
        let empty_conn = OdbcError::EmptyConnectionString;
        assert!(
            empty_conn.is_connection_error(),
            "EmptyConnectionString should be connection error"
        );

        // EnvironmentNotInitialized should be connection error
        let env_not_init = OdbcError::EnvironmentNotInitialized;
        assert!(
            env_not_init.is_connection_error(),
            "EnvironmentNotInitialized should be connection error"
        );

        // SQLSTATE '08xxx' should be connection error
        let conn_sqlstate = OdbcError::Structured {
            sqlstate: [b'0', b'8', b'0', b'0', b'1'],
            native_code: 0,
            message: "Connection failed".to_string(),
        };
        assert!(
            conn_sqlstate.is_connection_error(),
            "SQLSTATE '08xxx' should be connection error"
        );

        // Non-connection errors
        let validation_error = OdbcError::ValidationError("Invalid input".to_string());
        assert!(
            !validation_error.is_connection_error(),
            "Validation errors should not be connection errors"
        );

        let query_error = OdbcError::Structured {
            sqlstate: [b'4', b'2', b'S', b'0', b'2'],
            native_code: 0,
            message: "Table not found".to_string(),
        };
        assert!(
            !query_error.is_connection_error(),
            "Query errors should not be connection errors"
        );
    }

    #[test]
    fn test_error_category() {
        // ValidationError → Validation
        let validation_error = OdbcError::ValidationError("Invalid input".to_string());
        assert_eq!(
            validation_error.error_category(),
            ErrorCategory::Validation,
            "ValidationError should map to Validation category"
        );

        // Connection errors → ConnectionLost
        let conn_error = OdbcError::EmptyConnectionString;
        assert_eq!(
            conn_error.error_category(),
            ErrorCategory::ConnectionLost,
            "Connection errors should map to ConnectionLost category"
        );

        let conn_sqlstate = OdbcError::Structured {
            sqlstate: [b'0', b'8', b'0', b'0', b'1'],
            native_code: 0,
            message: "Connection failed".to_string(),
        };
        assert_eq!(
            conn_sqlstate.error_category(),
            ErrorCategory::ConnectionLost,
            "SQLSTATE '08xxx' should map to ConnectionLost category"
        );

        // Retryable errors → Transient
        let pool_error = OdbcError::PoolError("Pool exhausted".to_string());
        assert_eq!(
            pool_error.error_category(),
            ErrorCategory::Transient,
            "Pool errors should map to Transient category"
        );

        let timeout_error = OdbcError::InternalError("Query timeout".to_string());
        assert_eq!(
            timeout_error.error_category(),
            ErrorCategory::Transient,
            "Timeout errors should map to Transient category"
        );

        // Other errors → Fatal
        let fatal_error = OdbcError::Structured {
            sqlstate: [b'2', b'3', b'0', b'0', b'0'],
            native_code: 0,
            message: "Constraint violation".to_string(),
        };
        assert_eq!(
            fatal_error.error_category(),
            ErrorCategory::Fatal,
            "Non-retryable, non-connection errors should map to Fatal category"
        );

        let invalid_handle = OdbcError::InvalidHandle(999);
        assert_eq!(
            invalid_handle.error_category(),
            ErrorCategory::Fatal,
            "InvalidHandle should map to Fatal category"
        );
    }
}

//! Regression tests for StructuredError format, serialization, and edge cases.
//!
//! Ensures format stability, SQLSTATE mapping, native code preservation,
//! roundtrip consistency, message sanitization, and concurrent safety across
//! Rust and Dart boundaries.

use odbc_engine::security::sanitize_connection_string;
use odbc_engine::StructuredError;
use std::thread;

/// Binary format: [5 sqlstate][4 native_code LE][4 msg_len LE][msg bytes]
const FORMAT_HEADER_SIZE: usize = 13;

#[test]
fn test_structured_error_format_stability() {
    let err = StructuredError {
        sqlstate: [b'4', b'2', b'S', b'0', b'2'],
        native_code: 208,
        message: "Table not found".to_string(),
    };
    let buf = err.serialize();

    assert_eq!(buf.len(), FORMAT_HEADER_SIZE + err.message.len());
    assert_eq!(&buf[0..5], b"42S02", "SQLSTATE must be 5 bytes at offset 0");
    assert_eq!(
        i32::from_le_bytes([buf[5], buf[6], buf[7], buf[8]]),
        208,
        "native_code must be 4 bytes LE at offset 5"
    );
    assert_eq!(
        u32::from_le_bytes([buf[9], buf[10], buf[11], buf[12]]) as usize,
        err.message.len(),
        "msg_len must be 4 bytes LE at offset 9"
    );
}

#[test]
fn test_structured_error_sqlstate_mapping() {
    let sqlstates = [
        ([b'0', b'8', b'S', b'0', b'1'], "08S01"),
        ([b'4', b'2', b'S', b'0', b'2'], "42S02"),
        ([b'2', b'3', b'0', b'0', b'0'], "23000"),
        ([b'4', b'2', b'0', b'0', b'0'], "42000"),
        ([b'0', b'A', b'0', b'0', b'0'], "0A000"),
    ];
    for (bytes, expected) in sqlstates {
        let err = StructuredError {
            sqlstate: bytes,
            native_code: 0,
            message: String::new(),
        };
        let buf = err.serialize();
        let restored = StructuredError::deserialize(&buf).expect("deserialize");
        assert_eq!(
            &restored.sqlstate[..],
            bytes,
            "SQLSTATE {:?} must roundtrip",
            expected
        );
    }
}

#[test]
fn test_structured_error_native_code_preservation() {
    let codes = [0i32, 42, -1, 208, i32::MIN, i32::MAX];
    for native_code in codes {
        let err = StructuredError {
            sqlstate: [0u8; 5],
            native_code,
            message: "test".to_string(),
        };
        let buf = err.serialize();
        let restored = StructuredError::deserialize(&buf).expect("deserialize");
        assert_eq!(
            restored.native_code, native_code,
            "native_code {} must be preserved",
            native_code
        );
    }
}

#[test]
fn test_structured_error_serialization_roundtrip() {
    let original = StructuredError {
        sqlstate: [b'H', b'Y', b'0', b'0', b'0'],
        native_code: -1234,
        message: "General error: connection refused".to_string(),
    };
    let buf = original.serialize();
    let restored = StructuredError::deserialize(&buf).expect("roundtrip");
    assert_eq!(restored.sqlstate, original.sqlstate);
    assert_eq!(restored.native_code, original.native_code);
    assert_eq!(restored.message, original.message);
}

#[test]
fn test_structured_error_empty_message() {
    let err = StructuredError {
        sqlstate: [b'2', b'3', b'0', b'0', b'0'],
        native_code: 0,
        message: String::new(),
    };
    let buf = err.serialize();
    let restored = StructuredError::deserialize(&buf).expect("deserialize");
    assert_eq!(restored.message, "");
}

#[test]
fn test_structured_error_concurrent_access() {
    // Multiple threads serialize/deserialize different StructuredErrors in parallel.
    // Ensures no shared mutable state and no race conditions.
    let handles: Vec<_> = (0..8)
        .map(|i| {
            thread::spawn(move || {
                let err = StructuredError {
                    sqlstate: [b'0' + (i % 10) as u8, b'0', b'0', b'0', b'0'],
                    native_code: i,
                    message: format!("Error {}", i),
                };
                let buf = err.serialize();
                let restored = StructuredError::deserialize(&buf).expect("deserialize");
                assert_eq!(restored.sqlstate, err.sqlstate);
                assert_eq!(restored.native_code, err.native_code);
                assert_eq!(restored.message, err.message);
            })
        })
        .collect();
    for h in handles {
        h.join().expect("thread");
    }
}

#[test]
fn test_structured_error_message_sanitization() {
    // Error messages from ODBC may contain connection strings. Sanitization
    // must redact secrets before logging or exposing to callers.
    let raw_message = "Connection failed: DSN=prod;Server=localhost;PWD=secret123;UID=sa";
    let sanitized = sanitize_connection_string(raw_message);
    assert!(
        !sanitized.contains("secret123"),
        "PWD must be redacted from error messages"
    );
    assert!(
        sanitized.contains("PWD=***"),
        "PWD should be replaced with ***"
    );
}

#[test]
fn test_structured_error_very_long_message() {
    let msg = "x".repeat(64 * 1024);
    let err = StructuredError {
        sqlstate: [b'2', b'3', b'0', b'0', b'0'],
        native_code: 0,
        message: msg.clone(),
    };
    let buf = err.serialize();
    let restored = StructuredError::deserialize(&buf).expect("deserialize");
    assert_eq!(restored.message.len(), msg.len());
    assert_eq!(restored.message, msg);
}

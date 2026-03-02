//! Sanitization helpers for sensitive data in logs and traces.
//!
//! Redacts credentials from ODBC connection strings before logging/audit.

/// Redacts password and similar secrets from ODBC connection strings.
///
/// Replaces values for keys (case-insensitive): PWD, Password, pwd, password.
/// Keeps other key-value pairs (DSN, Server, Database, etc.) unchanged.
///
/// # Example
/// ```
/// # use odbc_engine::security::sanitize_connection_string;
/// let s = "DSN=prod;Server=localhost;PWD=secret123;UID=sa";
/// assert_eq!(sanitize_connection_string(s), "DSN=prod;Server=localhost;PWD=***;UID=sa");
/// ```
pub fn sanitize_connection_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    let bytes = s.as_bytes();
    let len = bytes.len();

    while i < len {
        let start = i;
        while i < len && bytes[i] != b';' && bytes[i] != b'=' {
            i += 1;
        }
        let key_end = i;
        if i < len && bytes[i] == b'=' {
            i += 1;
            let value_start = i;
            while i < len && bytes[i] != b';' {
                i += 1;
            }
            let value_end = i;

            let key = &s[start..key_end];
            let is_secret = matches!(
                key.to_lowercase().as_str(),
                "pwd" | "password" | "passwd" | "secret"
            );

            if !out.is_empty() {
                out.push(';');
            }
            out.push_str(key);
            out.push('=');
            if is_secret {
                out.push_str("***");
            } else {
                out.push_str(&s[value_start..value_end]);
            }
        } else {
            if !out.is_empty() {
                out.push(';');
            }
            out.push_str(&s[start..key_end]);
        }
        if i < len && bytes[i] == b';' {
            i += 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sanitize_redacts_pwd() {
        let s = "DSN=prod;Server=localhost;PWD=secret123;UID=sa";
        assert_eq!(
            sanitize_connection_string(s),
            "DSN=prod;Server=localhost;PWD=***;UID=sa"
        );
    }

    #[test]
    fn test_sanitize_redacts_password() {
        let s = "Driver={SQL Server};Password=myPass;Server=localhost";
        assert_eq!(
            sanitize_connection_string(s),
            "Driver={SQL Server};Password=***;Server=localhost"
        );
    }

    #[test]
    fn test_sanitize_keeps_non_secrets() {
        let s = "DSN=test;Server=localhost;Database=mydb";
        assert_eq!(sanitize_connection_string(s), s);
    }

    #[test]
    fn test_sanitize_empty() {
        assert_eq!(sanitize_connection_string(""), "");
    }

    #[test]
    fn test_sanitize_single_key() {
        let s = "PWD=only";
        assert_eq!(sanitize_connection_string(s), "PWD=***");
    }
}

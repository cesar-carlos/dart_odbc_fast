//! Sanitization helpers for sensitive data in logs and traces.
//!
//! Redacts credentials from ODBC connection strings before logging/audit.

/// Keys whose values must be redacted (case-insensitive).
///
/// Includes the canonical ODBC password keys plus common API/token keys
/// that can appear in connection strings of cloud-style drivers.
const SECRET_KEYS: &[&str] = &[
    "pwd",
    "password",
    "passwd",
    "secret",
    "token",
    "apikey",
    "api_key",
    "accesstoken",
    "access_token",
    "authorization",
    "auth",
    "sas",
    "sastoken",
    "sas_token",
    "connectionstring",
    "primarykey",
    "secondarykey",
];

fn is_secret_key(key: &str) -> bool {
    let lower = key.trim().to_ascii_lowercase();
    SECRET_KEYS.contains(&lower.as_str())
}

/// Redacts password and similar secrets from ODBC connection strings.
///
/// Replaces values for known secret keys (case-insensitive). Properly handles
/// values wrapped in `{...}` braces (the ODBC escape syntax used to allow
/// values containing `;` or `=`).
///
/// Other key-value pairs (DSN, Server, Database, etc.) are kept verbatim.
///
/// # Example
/// ```
/// # use odbc_engine::security::sanitize_connection_string;
/// let s = "DSN=prod;Server=localhost;PWD=secret123;UID=sa";
/// assert_eq!(sanitize_connection_string(s), "DSN=prod;Server=localhost;PWD=***;UID=sa");
/// ```
pub fn sanitize_connection_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let len = bytes.len();
    let mut i = 0;
    let mut first = true;

    while i < len {
        // Read key (until '=' or ';').
        let key_start = i;
        while i < len && bytes[i] != b'=' && bytes[i] != b';' {
            i += 1;
        }
        let key_end = i;

        // Append separator now so empty values still emit the key.
        if !first {
            out.push(';');
        }
        first = false;
        out.push_str(&s[key_start..key_end]);

        // No '=' → bare token.
        if i >= len || bytes[i] == b';' {
            if i < len {
                i += 1; // skip ';'
            }
            continue;
        }

        // Consume '='.
        out.push('=');
        i += 1;

        // Read value, honouring `{...}` escaping (value may contain ';' inside braces).
        let value_start = i;
        if i < len && bytes[i] == b'{' {
            i += 1;
            while i < len && bytes[i] != b'}' {
                i += 1;
            }
            if i < len {
                i += 1; // include closing '}'
            }
            // Trailing chars up to ';' are part of the value too.
            while i < len && bytes[i] != b';' {
                i += 1;
            }
        } else {
            while i < len && bytes[i] != b';' {
                i += 1;
            }
        }
        let value_end = i;

        if is_secret_key(&s[key_start..key_end]) {
            out.push_str("***");
        } else {
            out.push_str(&s[value_start..value_end]);
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

    #[test]
    fn test_sanitize_token_key() {
        let s = "Driver={X};Token=abcd1234";
        assert_eq!(sanitize_connection_string(s), "Driver={X};Token=***");
    }

    #[test]
    fn test_sanitize_api_key() {
        let s = "Driver={X};ApiKey=abcd1234;Server=h";
        assert_eq!(
            sanitize_connection_string(s),
            "Driver={X};ApiKey=***;Server=h"
        );
    }

    #[test]
    fn test_sanitize_value_with_semicolon_in_braces() {
        // Values inside `{}` may contain semicolons; we must not split them.
        let s = "Driver={SQL Server};Pwd={se;cret};Server=h";
        assert_eq!(
            sanitize_connection_string(s),
            "Driver={SQL Server};Pwd=***;Server=h"
        );
    }

    #[test]
    fn test_sanitize_authorization_key() {
        let s = "Url=https://db.example;Authorization=Bearer xxx;Database=main";
        assert_eq!(
            sanitize_connection_string(s),
            "Url=https://db.example;Authorization=***;Database=main"
        );
    }

    #[test]
    fn test_sanitize_case_insensitive_keys() {
        let s = "password=x;PASSWORD=y;PwD=z";
        assert_eq!(
            sanitize_connection_string(s),
            "password=***;PASSWORD=***;PwD=***"
        );
    }
}

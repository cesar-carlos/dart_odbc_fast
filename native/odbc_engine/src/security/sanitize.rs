//! Sanitization helpers for sensitive data in logs and traces.
//!
//! Redacts credentials from ODBC connection strings before logging/audit.

use super::connection_string::for_each_connection_string_pair;

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
    let mut first = true;
    for_each_connection_string_pair(s, |key, value| {
        if !first {
            out.push(';');
        }
        first = false;
        out.push_str(key);
        let Some(raw) = value else {
            return;
        };
        out.push('=');
        if is_secret_key(key) {
            out.push_str("***");
        } else {
            out.push_str(raw);
        }
    });
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

    #[test]
    fn should_redact_sas_and_api_key_aliases() {
        let s = "DSN=x;SAS=sig;Api_Key=k;Access_Token=t";
        assert_eq!(
            sanitize_connection_string(s),
            "DSN=x;SAS=***;Api_Key=***;Access_Token=***"
        );
    }

    #[test]
    fn should_preserve_bare_token_without_equals() {
        let s = "DSN=prod;Trusted_Connection;PWD=secret";
        assert_eq!(
            sanitize_connection_string(s),
            "DSN=prod;Trusted_Connection;PWD=***"
        );
    }

    #[test]
    fn should_redact_key_with_surrounding_whitespace() {
        let s = "  Password  =p;Server=h";
        assert_eq!(sanitize_connection_string(s), "  Password  =***;Server=h");
    }

    #[test]
    fn should_drop_trailing_empty_segment_after_final_semicolon() {
        let s = "DSN=a;Server=b;";
        assert_eq!(sanitize_connection_string(s), "DSN=a;Server=b");
    }
}

//! Brace-aware ODBC connection-string token helpers.
//!
//! Shared by credential sanitization and driver-engine heuristics so `{...}`
//! values that contain `;` are not split.

/// Visit each `key` / optional `value` pair in an ODBC connection string.
///
/// Bare tokens (no `=`) yield `value = None`. Empty leftover segments after a
/// trailing `;` are not emitted.
pub(crate) fn for_each_connection_string_pair(s: &str, mut visit: impl FnMut(&str, Option<&str>)) {
    let bytes = s.as_bytes();
    let len = bytes.len();
    let mut i = 0;
    while i < len {
        let key_start = i;
        while i < len && bytes[i] != b'=' && bytes[i] != b';' {
            i += 1;
        }
        let key_end = i;

        if i >= len || bytes[i] == b';' {
            let key = &s[key_start..key_end];
            if !key.is_empty() {
                visit(key, None);
            }
            if i < len {
                i += 1;
            }
            continue;
        }

        i += 1;
        let value_start = i;
        if i < len && bytes[i] == b'{' {
            i += 1;
            while i < len && bytes[i] != b'}' {
                i += 1;
            }
            if i < len {
                i += 1;
            }
            while i < len && bytes[i] != b';' {
                i += 1;
            }
        } else {
            while i < len && bytes[i] != b';' {
                i += 1;
            }
        }
        let value_end = i;
        visit(&s[key_start..key_end], Some(&s[value_start..value_end]));
        if i < len && bytes[i] == b';' {
            i += 1;
        }
    }
}

/// Strip a single layer of ODBC `{...}` braces from a connection-string value.
pub(crate) fn unwrap_odbc_braces(value: &str) -> &str {
    let trimmed = value.trim();
    if trimmed.len() >= 2 && trimmed.starts_with('{') && trimmed.ends_with('}') {
        trimmed[1..trimmed.len() - 1].trim()
    } else {
        trimmed
    }
}

/// Return the `Driver=` token from a connection string, with `{}` stripped.
///
/// DSN-only strings (no `Driver=`) return `None`. Matching is case-insensitive
/// on the key. The first `Driver=` wins.
pub fn driver_token_from_connection_string(s: &str) -> Option<String> {
    let mut found: Option<String> = None;
    for_each_connection_string_pair(s, |key, value| {
        if found.is_some() {
            return;
        }
        if !key.trim().eq_ignore_ascii_case("driver") {
            return;
        }
        let Some(raw) = value else {
            return;
        };
        let token = unwrap_odbc_braces(raw);
        if !token.is_empty() {
            found = Some(token.to_string());
        }
    });
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn driver_token_strips_braces() {
        assert_eq!(
            driver_token_from_connection_string("Driver={SQL Server};Server=h;"),
            Some("SQL Server".to_string())
        );
    }

    #[test]
    fn driver_token_is_case_insensitive_and_unquoted() {
        assert_eq!(
            driver_token_from_connection_string("DRIVER=SQLSERVER;SERVER=localhost"),
            Some("SQLSERVER".to_string())
        );
    }

    #[test]
    fn driver_token_ignores_uid_and_database() {
        assert_eq!(
            driver_token_from_connection_string("Driver={MySQL ODBC};Database=postgres_mirror;"),
            Some("MySQL ODBC".to_string())
        );
    }

    #[test]
    fn driver_token_none_for_dsn_only() {
        assert_eq!(
            driver_token_from_connection_string("DSN=prod;UID=postgres;PWD=x"),
            None
        );
    }

    #[test]
    fn driver_token_handles_semicolon_inside_braces() {
        assert_eq!(
            driver_token_from_connection_string("Driver={Foo;Bar};Server=h;"),
            Some("Foo;Bar".to_string())
        );
    }

    #[test]
    fn unwrap_odbc_braces_trims_inner_whitespace() {
        assert_eq!(unwrap_odbc_braces(" { DB2 } "), "DB2");
        assert_eq!(unwrap_odbc_braces("plain"), "plain");
        assert_eq!(unwrap_odbc_braces("{}"), "");
        assert_eq!(unwrap_odbc_braces("{unclosed"), "{unclosed");
    }

    #[test]
    fn driver_token_skips_empty_and_bare_driver_keys() {
        assert_eq!(
            driver_token_from_connection_string("Driver={};Server=h"),
            None
        );
        assert_eq!(
            driver_token_from_connection_string("Driver=;Server=h"),
            None
        );
        assert_eq!(
            driver_token_from_connection_string("DRIVER;Server=localhost"),
            None
        );
    }

    #[test]
    fn driver_token_first_driver_wins() {
        assert_eq!(
            driver_token_from_connection_string("Driver={MySQL};Driver={PostgreSQL};"),
            Some("MySQL".to_string())
        );
    }

    #[test]
    fn driver_token_keeps_unclosed_brace_value() {
        assert_eq!(
            driver_token_from_connection_string("Driver={MySQL ODBC"),
            Some("{MySQL ODBC".to_string())
        );
    }

    #[test]
    fn for_each_emits_bare_tokens_and_skips_empty_segments() {
        let mut pairs = Vec::new();
        for_each_connection_string_pair("DSN=a;;Trusted_Connection;PWD=x;", |key, value| {
            pairs.push((key.to_string(), value.map(str::to_string)));
        });
        assert_eq!(
            pairs,
            vec![
                ("DSN".to_string(), Some("a".to_string())),
                ("Trusted_Connection".to_string(), None),
                ("PWD".to_string(), Some("x".to_string())),
            ]
        );
    }
}

use std::time::Duration;

const POOL_TEST_ON_CHECKOUT_ENV: &str = "ODBC_POOL_TEST_ON_CHECKOUT";
const POOL_HEALTH_CHECK_QUERY_ENV: &str = "ODBC_POOL_HEALTH_CHECK_QUERY";
const POOL_SESSION_RESET_ENV: &str = "ODBC_POOL_SESSION_RESET";
pub(crate) const DEFAULT_TEST_ON_CHECKOUT: bool = true;
pub(crate) const DEFAULT_HEALTH_CHECK_QUERY: &str = "SELECT 1";
pub(crate) const DEFAULT_SESSION_RESET_ON_CHECKOUT: bool = true;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PoolConfig {
    pub sanitized_connection_string: String,
    pub test_on_check_out: bool,
    pub health_check_query: String,
    pub session_reset_on_checkout: Option<bool>,
}

impl PoolConfig {
    pub(crate) fn from_connection_string(connection_string: &str) -> Self {
        let (
            sanitized_connection_string,
            conn_override,
            health_check_query,
            session_reset_override,
        ) = parse_pool_options_from_connection_string(connection_string);
        let test_on_check_out =
            resolve_checkout_validation(conn_override, read_checkout_validation_from_env());
        let health_check_query =
            resolve_health_check_query(health_check_query, read_health_check_query_from_env());

        Self {
            sanitized_connection_string,
            test_on_check_out,
            health_check_query,
            session_reset_on_checkout: session_reset_override,
        }
    }
}

fn is_pool_checkout_option(key: &str) -> bool {
    matches!(
        key,
        "pooltestoncheckout"
            | "testoncheckout"
            | "pool_test_on_checkout"
            | "pool_test_on_check_out"
            | "test_on_checkout"
            | "test_on_check_out"
    )
}

fn is_pool_health_check_option(key: &str) -> bool {
    matches!(
        key,
        "poolhealthcheckquery"
            | "healthcheckquery"
            | "pool_health_check_query"
            | "health_check_query"
    )
}

fn is_pool_session_reset_option(key: &str) -> bool {
    matches!(
        key,
        "poolsessionreset"
            | "sessionreset"
            | "pool_session_reset"
            | "session_reset"
            | "session_reset_on_checkout"
            | "pool_session_reset_on_checkout"
    )
}

fn parse_bool_flag(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

fn split_connection_string_parts(connection_string: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut start = 0usize;
    let mut brace_depth = 0u32;

    for (idx, ch) in connection_string.char_indices() {
        match ch {
            '{' => brace_depth = brace_depth.saturating_add(1),
            '}' => brace_depth = brace_depth.saturating_sub(1),
            ';' if brace_depth == 0 => {
                parts.push(&connection_string[start..idx]);
                start = idx + ch.len_utf8();
            }
            _ => {}
        }
    }
    parts.push(&connection_string[start..]);
    parts
}

pub(crate) fn parse_pool_options_from_connection_string(
    connection_string: &str,
) -> (String, Option<bool>, Option<String>, Option<bool>) {
    let mut sanitized_parts = Vec::new();
    let mut conn_override = None;
    let mut health_check_query = None;
    let mut session_reset_override = None;

    for part in split_connection_string_parts(connection_string) {
        let trimmed = part.trim();
        if trimmed.is_empty() {
            continue;
        }

        if let Some((key, raw_value)) = part.split_once('=') {
            let normalized_key = key.trim().to_ascii_lowercase();
            if is_pool_checkout_option(&normalized_key) {
                let value = raw_value.trim().trim_matches(|c| c == '{' || c == '}');
                if let Some(parsed) = parse_bool_flag(value) {
                    conn_override = Some(parsed);
                }
                continue;
            }
            if is_pool_health_check_option(&normalized_key) {
                let value = raw_value.trim().trim_matches(|c| c == '{' || c == '}');
                if !value.is_empty() {
                    health_check_query = Some(value.to_string());
                }
                continue;
            }
            if is_pool_session_reset_option(&normalized_key) {
                let value = raw_value.trim().trim_matches(|c| c == '{' || c == '}');
                if let Some(parsed) = parse_bool_flag(value) {
                    session_reset_override = Some(parsed);
                }
                continue;
            }
        }

        sanitized_parts.push(trimmed);
    }

    let mut sanitized_connection_string = sanitized_parts.join(";");
    if connection_string.trim_end().ends_with(';') && !sanitized_connection_string.is_empty() {
        sanitized_connection_string.push(';');
    }

    (
        sanitized_connection_string,
        conn_override,
        health_check_query,
        session_reset_override,
    )
}

fn read_checkout_validation_from_env() -> Option<bool> {
    std::env::var(POOL_TEST_ON_CHECKOUT_ENV)
        .ok()
        .and_then(|value| parse_bool_flag(&value))
}

pub(crate) fn resolve_checkout_validation(
    conn_override: Option<bool>,
    env_override: Option<bool>,
) -> bool {
    conn_override
        .or(env_override)
        .unwrap_or(DEFAULT_TEST_ON_CHECKOUT)
}

fn read_health_check_query_from_env() -> Option<String> {
    std::env::var(POOL_HEALTH_CHECK_QUERY_ENV)
        .ok()
        .filter(|s| !s.trim().is_empty())
}

fn read_session_reset_from_env() -> Option<bool> {
    std::env::var(POOL_SESSION_RESET_ENV)
        .ok()
        .and_then(|value| parse_bool_flag(&value))
}

pub(crate) fn read_session_reset_from_env_for_pool() -> Option<bool> {
    read_session_reset_from_env()
}

pub(crate) fn resolve_session_reset_on_checkout(
    options_override: Option<bool>,
    conn_override: Option<bool>,
    env_override: Option<bool>,
) -> bool {
    options_override
        .or(conn_override)
        .or(env_override)
        .unwrap_or(DEFAULT_SESSION_RESET_ON_CHECKOUT)
}

pub(crate) fn resolve_health_check_query(
    conn_override: Option<String>,
    env_override: Option<String>,
) -> String {
    conn_override
        .or(env_override)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| DEFAULT_HEALTH_CHECK_QUERY.to_string())
}

/// Options for pool creation (eviction, timeouts).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PoolOptions {
    /// Idle connections are closed after this duration.
    pub idle_timeout: Option<Duration>,
    /// Connections are closed when they exceed this lifetime (checked on return).
    pub max_lifetime: Option<Duration>,
    /// Maximum time `get()` will wait for an available connection.
    /// Defaults to 30 s when `None`. (A9)
    pub connection_timeout: Option<Duration>,
    /// When `Some(false)`, skip `pool_session_reset` on checkout (trusted pool).
    /// `None` defers to DSN `Pool_Session_Reset` / env `ODBC_POOL_SESSION_RESET`
    /// / default `true`. Checkin reset remains unconditional.
    pub session_reset_on_checkout: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PoolRuntimeConfig {
    pub connection_string: String,
    pub test_on_check_out: bool,
    pub health_check_query: String,
    pub session_reset_on_checkout: bool,
    pub options: PoolOptions,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_pool_option_from_connection_string_true() {
        let conn = "DSN=MainDsn;Pool_Test_On_Checkout=true;";
        let config = PoolConfig::from_connection_string(conn);
        assert_eq!(config.sanitized_connection_string, "DSN=MainDsn;");
        assert!(config.test_on_check_out);
    }

    #[test]
    fn test_parse_pool_option_from_connection_string_false() {
        let conn = "DSN=MainDsn;test_on_check_out=0;UID=sa";
        let config = PoolConfig::from_connection_string(conn);
        assert_eq!(config.sanitized_connection_string, "DSN=MainDsn;UID=sa");
        assert!(!config.test_on_check_out);
    }

    #[test]
    fn test_parse_pool_option_keeps_semicolon_inside_braces() {
        let conn = "PWD={ab;c};PoolTestOnCheckout=false;DSN=MainDsn";
        let (sanitized, override_flag, health_query, _) =
            parse_pool_options_from_connection_string(conn);
        assert_eq!(sanitized, "PWD={ab;c};DSN=MainDsn");
        assert_eq!(override_flag, Some(false));
        assert_eq!(health_query, None);
    }

    #[test]
    fn test_parse_pool_option_ignores_invalid_value() {
        let conn = "DSN=MainDsn;PoolTestOnCheckout=maybe;";
        let (sanitized, override_flag, health_query, _) =
            parse_pool_options_from_connection_string(conn);
        assert_eq!(sanitized, "DSN=MainDsn;");
        assert_eq!(override_flag, None);
        assert_eq!(health_query, None);
    }

    #[test]
    fn test_parse_pool_health_check_query_from_connection_string() {
        let conn = "DSN=MainDsn;PoolHealthCheckQuery=SELECT 1 AS ping;";
        let (sanitized, _, health_query, _) = parse_pool_options_from_connection_string(conn);
        assert_eq!(sanitized, "DSN=MainDsn;");
        assert_eq!(health_query, Some("SELECT 1 AS ping".to_string()));
    }

    #[test]
    fn test_parse_pool_health_check_query_default() {
        let (_, _, health_query, _) = parse_pool_options_from_connection_string("DSN=MainDsn;");
        assert_eq!(health_query, None);
    }

    #[test]
    fn test_resolve_checkout_validation_default_is_true() {
        assert!(resolve_checkout_validation(None, None));
    }

    #[test]
    fn test_resolve_checkout_validation_env_override() {
        assert!(!resolve_checkout_validation(None, Some(false)));
    }

    #[test]
    fn test_resolve_checkout_validation_connection_string_overrides_env() {
        assert!(resolve_checkout_validation(Some(true), Some(false)));
    }

    #[test]
    fn should_parse_bool_yes_and_on() {
        assert_eq!(parse_bool_flag("yes"), Some(true));
        assert_eq!(parse_bool_flag("ON"), Some(true));
        assert_eq!(parse_bool_flag("off"), Some(false));
        assert_eq!(parse_bool_flag("nope"), None);
    }

    #[test]
    fn should_resolve_health_check_from_connection_string() {
        let conn = "DSN=x;health_check_query=SELECT CURRENT_TIMESTAMP;";
        let config = PoolConfig::from_connection_string(conn);
        assert_eq!(config.health_check_query, "SELECT CURRENT_TIMESTAMP");
        assert_eq!(config.sanitized_connection_string, "DSN=x;");
    }

    #[test]
    fn should_strip_pool_test_on_checkout_aliases() {
        let conn = "DSN=a;Pool_Test_On_Checkout=false;UID=u";
        let (sanitized, flag, _, _) = parse_pool_options_from_connection_string(conn);
        assert_eq!(sanitized, "DSN=a;UID=u");
        assert!(!flag.expect("parsed flag"));
    }

    #[test]
    fn should_split_connection_string_parts_inside_braces() {
        let parts = split_connection_string_parts("PWD={a;b};DSN=x");
        assert_eq!(parts, vec!["PWD={a;b}", "DSN=x"]);
    }

    #[test]
    fn should_default_pool_options_match_struct_default() {
        let opts = PoolOptions::default();
        assert_eq!(opts.idle_timeout, None);
        assert_eq!(opts.max_lifetime, None);
        assert_eq!(opts.connection_timeout, None);
        assert_eq!(opts.session_reset_on_checkout, None);
    }

    #[test]
    fn should_parse_session_reset_from_connection_string() {
        let conn = "DSN=MainDsn;Pool_Session_Reset=false;";
        let config = PoolConfig::from_connection_string(conn);
        assert_eq!(config.sanitized_connection_string, "DSN=MainDsn;");
        assert_eq!(config.session_reset_on_checkout, Some(false));
    }

    #[test]
    fn should_resolve_session_reset_precedence() {
        assert!(!resolve_session_reset_on_checkout(
            Some(false),
            Some(true),
            Some(true)
        ));
        assert!(!resolve_session_reset_on_checkout(
            None,
            Some(false),
            Some(true)
        ));
        assert!(resolve_session_reset_on_checkout(None, None, None));
    }

    #[test]
    fn should_recognize_pool_checkout_option_aliases() {
        assert!(is_pool_checkout_option("pooltestoncheckout"));
        assert!(is_pool_checkout_option("test_on_check_out"));
        assert!(!is_pool_checkout_option("dsn"));
    }

    #[test]
    fn should_recognize_health_check_query_aliases() {
        assert!(is_pool_health_check_option("health_check_query"));
        assert!(is_pool_health_check_option("poolhealthcheckquery"));
        assert!(!is_pool_health_check_option("password"));
    }

    #[test]
    fn should_resolve_health_check_default_when_overrides_empty() {
        assert_eq!(
            resolve_health_check_query(None, Some("   ".to_string())),
            "SELECT 1"
        );
    }
}

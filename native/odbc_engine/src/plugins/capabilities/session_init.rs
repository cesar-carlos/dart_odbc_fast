//! Per-driver session initialization.
//!
//! Generates the post-connect setup SQL appropriate to each engine
//! (`SET application_name`, `SET TIME ZONE`, `ALTER SESSION SET NLS_*`,
//! `PRAGMA foreign_keys=ON`, ...). The runtime executes the returned
//! statements right after `SQLConnect` returns, before any user query.

/// Caller-provided knobs that influence which initialization statements are
/// emitted. Fields are `Option`: `None` means "do not touch this setting".
#[derive(Debug, Clone, Default)]
pub struct SessionOptions {
    /// Identifies the application in server-side process listings
    /// (`pg_stat_activity`, `INFORMATION_SCHEMA.PROCESSLIST`, ...).
    pub application_name: Option<String>,
    /// IANA / engine-specific timezone name (e.g. `"UTC"`, `"America/Sao_Paulo"`).
    pub timezone: Option<String>,
    /// Client encoding (`utf8mb4`, `WE8MSWIN1252`, ...).
    pub charset: Option<String>,
    /// Default schema / search path.
    pub schema: Option<String>,
    /// Engine-specific raw SQL to append after the standard setup.
    pub extra_sql: Vec<String>,
}

impl SessionOptions {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_application_name(mut self, name: impl Into<String>) -> Self {
        self.application_name = Some(name.into());
        self
    }

    pub fn with_timezone(mut self, tz: impl Into<String>) -> Self {
        self.timezone = Some(tz.into());
        self
    }

    pub fn with_charset(mut self, cs: impl Into<String>) -> Self {
        self.charset = Some(cs.into());
        self
    }

    pub fn with_schema(mut self, schema: impl Into<String>) -> Self {
        self.schema = Some(schema.into());
        self
    }

    pub fn with_extra_sql(mut self, sql: impl Into<String>) -> Self {
        self.extra_sql.push(sql.into());
        self
    }
}

/// Capability trait for engines that benefit from a post-connect setup.
pub trait SessionInitializer: Send + Sync {
    /// Return the statements to execute after a fresh `SQLConnect`.
    /// Order matters: the runtime executes them sequentially and aborts on
    /// the first failure.
    fn initialization_sql(&self, opts: &SessionOptions) -> Vec<String>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_builder_chains() {
        let o = SessionOptions::new()
            .with_application_name("svc")
            .with_timezone("UTC")
            .with_charset("utf8mb4")
            .with_schema("public")
            .with_extra_sql("SET statement_timeout = 5000");
        assert_eq!(o.application_name.as_deref(), Some("svc"));
        assert_eq!(o.timezone.as_deref(), Some("UTC"));
        assert_eq!(o.charset.as_deref(), Some("utf8mb4"));
        assert_eq!(o.schema.as_deref(), Some("public"));
        assert_eq!(o.extra_sql, vec!["SET statement_timeout = 5000"]);
    }

    #[test]
    fn default_options_are_empty() {
        let o = SessionOptions::default();
        assert!(o.application_name.is_none());
        assert!(o.timezone.is_none());
        assert!(o.charset.is_none());
        assert!(o.schema.is_none());
        assert!(o.extra_sql.is_empty());
    }
}

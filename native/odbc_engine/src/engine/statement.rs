/// Prepared statement handle with execution options.
///
/// Contains SQL, connection info, and execution parameters like timeout,
/// buffer size limits, and fetch mode.
pub struct StatementHandle {
    pub(crate) conn_id: u32,
    pub(crate) sql: String,
    pub(crate) timeout_ms: u32,
    /// Maximum buffer size in bytes for result set (0 = use default).
    pub(crate) max_buffer_size: Option<u32>,
    /// Number of rows to fetch per batch (0 = use default).
    pub(crate) fetch_size: Option<u32>,
    /// Enable async fetch mode (non-blocking).
    pub(crate) async_fetch: bool,
}

impl StatementHandle {
    /// Creates a new statement handle with specified parameters.
    ///
    /// New optional fields (max_buffer_size, fetch_size, async_fetch) default to None/0
    /// to maintain backward compatibility with existing code.
    pub fn new(conn_id: u32, sql: String, timeout_ms: u32) -> Self {
        Self {
            conn_id,
            sql,
            timeout_ms,
            max_buffer_size: None,
            fetch_size: None,
            async_fetch: false,
        }
    }

    /// Creates a new statement handle with full options.
    pub fn with_options(
        conn_id: u32,
        sql: String,
        timeout_ms: u32,
        max_buffer_size: Option<u32>,
        fetch_size: Option<u32>,
        async_fetch: bool,
    ) -> Self {
        Self {
            conn_id,
            sql,
            timeout_ms,
            max_buffer_size,
            fetch_size,
            async_fetch,
        }
    }

    pub fn conn_id(&self) -> u32 {
        self.conn_id
    }

    pub fn sql(&self) -> &str {
        &self.sql
    }

    pub fn timeout_ms(&self) -> u32 {
        self.timeout_ms
    }

    /// Returns timeout in seconds (for ODBC API which uses seconds).
    /// Returns None if timeout_ms is 0 (no timeout).
    pub fn timeout_sec(&self) -> Option<usize> {
        if self.timeout_ms == 0 {
            None
        } else {
            Some((self.timeout_ms / 1000).max(1) as usize)
        }
    }

    /// Gets maximum buffer size.
    pub fn max_buffer_size(&self) -> Option<u32> {
        self.max_buffer_size
    }

    /// Gets fetch size (rows per batch).
    pub fn fetch_size(&self) -> Option<u32> {
        self.fetch_size
    }

    /// Checks if async fetch is enabled.
    pub fn async_fetch(&self) -> bool {
        self.async_fetch
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_statement_handle_new() {
        let s = StatementHandle::new(1, "SELECT 1".to_string(), 5000);
        assert_eq!(s.conn_id(), 1);
        assert_eq!(s.sql(), "SELECT 1");
        assert_eq!(s.timeout_ms(), 5000);
        assert_eq!(s.max_buffer_size(), None);
        assert_eq!(s.fetch_size(), None);
        assert!(!s.async_fetch());
    }

    #[test]
    fn test_statement_handle_new_with_options() {
        let s = StatementHandle::with_options(
            1,
            "SELECT 1".to_string(),
            5000,
            Some(1024 * 1024), // 1MB max buffer
            Some(100),         // 100 rows per fetch
            true,              // async fetch enabled
        );
        assert_eq!(s.conn_id(), 1);
        assert_eq!(s.sql(), "SELECT 1");
        assert_eq!(s.timeout_ms(), 5000);
        assert_eq!(s.max_buffer_size(), Some(1024 * 1024));
        assert_eq!(s.fetch_size(), Some(100));
        assert!(s.async_fetch());
    }

    #[test]
    fn test_statement_handle_timeout_sec_zero() {
        let s = StatementHandle::new(1, "SELECT 1".to_string(), 0);
        assert_eq!(s.timeout_sec(), None);
    }

    #[test]
    fn test_statement_handle_timeout_sec_nonzero() {
        let s = StatementHandle::new(1, "SELECT 1".to_string(), 3000);
        assert_eq!(s.timeout_sec(), Some(3));
    }

    #[test]
    fn test_statement_handle_timeout_sec_subsecond_rounds_up() {
        let s = StatementHandle::new(1, "SELECT 1".to_string(), 500);
        assert_eq!(s.timeout_sec(), Some(1));
    }
}

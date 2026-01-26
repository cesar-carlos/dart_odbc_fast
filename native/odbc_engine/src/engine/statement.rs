pub struct StatementHandle {
    pub(crate) conn_id: u32,
    pub(crate) sql: String,
    pub(crate) timeout_ms: u32,
}

impl StatementHandle {
    pub fn new(conn_id: u32, sql: String, timeout_ms: u32) -> Self {
        Self {
            conn_id,
            sql,
            timeout_ms,
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

    pub fn timeout_sec(&self) -> Option<usize> {
        if self.timeout_ms == 0 {
            None
        } else {
            Some((self.timeout_ms / 1000).max(1) as usize)
        }
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

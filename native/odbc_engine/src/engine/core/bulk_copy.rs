use crate::error::{OdbcError, Result};
use crate::protocol::BulkInsertPayload;

#[cfg(feature = "sqlserver-bcp")]
use odbc_api::Connection;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BulkCopyFormat {
    Native,
    Character,
    Unicode,
}

#[cfg(feature = "sqlserver-bcp")]
pub struct BulkCopyExecutor {
    batch_size: usize,
}

#[cfg(feature = "sqlserver-bcp")]
impl BulkCopyExecutor {
    pub fn new(batch_size: usize) -> Self {
        Self {
            batch_size: batch_size.max(1),
        }
    }

    pub fn batch_size(&self) -> usize {
        self.batch_size
    }

    /// Bulk copy from raw columnar byte data (for future native BCP).
    /// Not yet implemented; use `bulk_copy_from_payload` for structured data.
    pub fn bulk_copy_from_memory(
        &self,
        _conn: &Connection<'static>,
        _table: &str,
        _data: &[Vec<u8>],
    ) -> Result<usize> {
        Err(OdbcError::InternalError(
            "Native SQL Server BCP not yet implemented; use bulk_copy_from_payload".to_string(),
        ))
    }

    /// Bulk copy from structured payload using array binding (ODBC SQL_ATTR_PARAMSET_SIZE).
    /// Provides a functional path when sqlserver-bcp feature is enabled.
    /// Falls back to ArrayBinding; native bcp_* can be added later for SQL Server.
    pub fn bulk_copy_from_payload(
        &self,
        conn: &Connection<'static>,
        payload: &BulkInsertPayload,
    ) -> Result<usize> {
        let ab = super::ArrayBinding::new(self.batch_size);
        ab.bulk_insert_generic(conn, payload)
    }
}

#[cfg(not(feature = "sqlserver-bcp"))]
mod stub {
    use super::{BulkInsertPayload, OdbcError, Result};

    pub struct BulkCopyExecutor;

    impl BulkCopyExecutor {
        pub fn new(_batch_size: usize) -> Self {
            Self
        }

        pub fn batch_size(&self) -> usize {
            0
        }

        pub fn bulk_copy_from_memory(
            &self,
            _conn: &odbc_api::Connection<'static>,
            _table: &str,
            _data: &[Vec<u8>],
        ) -> Result<usize> {
            Err(OdbcError::InternalError(
                "Enable 'sqlserver-bcp' feature for BCP support".to_string(),
            ))
        }

        pub fn bulk_copy_from_payload(
            &self,
            _conn: &odbc_api::Connection<'static>,
            _payload: &BulkInsertPayload,
        ) -> Result<usize> {
            Err(OdbcError::InternalError(
                "Enable 'sqlserver-bcp' feature for BCP support".to_string(),
            ))
        }
    }
}

#[cfg(not(feature = "sqlserver-bcp"))]
pub use stub::BulkCopyExecutor;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bulk_copy_format_variants() {
        assert_eq!(format!("{:?}", BulkCopyFormat::Native), "Native");
        assert_eq!(format!("{:?}", BulkCopyFormat::Character), "Character");
        assert_eq!(format!("{:?}", BulkCopyFormat::Unicode), "Unicode");
    }

    #[test]
    fn test_bulk_copy_executor_stub() {
        let bcp = BulkCopyExecutor::new(1000);
        #[cfg(feature = "sqlserver-bcp")]
        assert_eq!(bcp.batch_size(), 1000);
        #[cfg(not(feature = "sqlserver-bcp"))]
        assert_eq!(bcp.batch_size(), 0);
    }

    #[cfg(feature = "sqlserver-bcp")]
    #[test]
    fn test_bulk_copy_executor_new_and_batch_size() {
        let bcp = BulkCopyExecutor::new(5000);
        assert_eq!(bcp.batch_size(), 5000);
    }

    #[cfg(feature = "sqlserver-bcp")]
    #[test]
    fn test_bulk_copy_executor_new_min_batch_size_one() {
        let bcp = BulkCopyExecutor::new(0);
        assert_eq!(bcp.batch_size(), 1);
    }
}

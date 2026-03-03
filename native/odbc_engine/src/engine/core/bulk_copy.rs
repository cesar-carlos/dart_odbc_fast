use crate::error::{OdbcError, Result};
use crate::protocol::BulkInsertPayload;

#[cfg(all(feature = "sqlserver-bcp", windows))]
use super::sqlserver_bcp;
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
    /// The current implementation requires structured payload metadata.
    pub fn bulk_copy_from_memory(
        &self,
        _conn: &Connection<'static>,
        _table: &str,
        _data: &[Vec<u8>],
    ) -> Result<usize> {
        Err(OdbcError::InternalError(
            "bulk_copy_from_memory requires native BCP row bindings and is not implemented; use bulk_copy_from_payload".to_string(),
        ))
    }

    /// Tries native SQL Server BCP first and falls back to ArrayBinding.
    pub fn bulk_copy_native(
        &self,
        conn: &Connection<'static>,
        payload: &BulkInsertPayload,
        conn_str: Option<&str>,
    ) -> Result<usize> {
        Self::validate_payload(payload)?;
        self.try_native_sqlserver_bcp(conn, payload, conn_str)
    }

    /// Bulk copy from structured payload with automatic fallback.
    /// conn_str: when Some (SQL Server), enables native BCP attempt via pre-connect SQL_COPT_SS_BCP.
    pub fn bulk_copy_from_payload(
        &self,
        conn: &Connection<'static>,
        payload: &BulkInsertPayload,
        conn_str: Option<&str>,
    ) -> Result<usize> {
        if payload.row_count == 0 {
            return Ok(0);
        }

        match self.bulk_copy_native(conn, payload, conn_str) {
            Ok(inserted) => Ok(inserted),
            Err(native_error) => {
                if !Self::should_fallback_to_array_binding(&native_error) {
                    return Err(native_error);
                }

                let ab = super::ArrayBinding::new(self.batch_size);
                match ab.bulk_insert_generic(conn, payload) {
                    Ok(inserted) => Ok(inserted),
                    Err(fallback_error) => Err(OdbcError::InternalError(format!(
                        "Bulk copy native failed ('{native_error}'), and fallback ArrayBinding also failed ('{fallback_error}')",
                    ))),
                }
            }
        }
    }

    fn try_native_sqlserver_bcp(
        &self,
        _conn: &Connection<'static>,
        payload: &BulkInsertPayload,
        conn_str: Option<&str>,
    ) -> Result<usize> {
        #[cfg(windows)]
        {
            if !Self::is_native_bcp_runtime_enabled() {
                return Err(OdbcError::UnsupportedFeature(
                    "Native SQL Server BCP is disabled by default due to known stability issues. Set ODBC_ENABLE_UNSTABLE_NATIVE_BCP=1 to enable experimental native path".to_string(),
                ));
            }
            sqlserver_bcp::probe_native_bcp_support()?;
            let conn_str = conn_str.ok_or_else(|| {
                OdbcError::UnsupportedFeature(
                    "Native SQL Server BCP requires connection string for pre-connect SQL_COPT_SS_BCP; not available in this context".to_string(),
                )
            })?;

            if !Self::is_sql_server_conn_str(conn_str) {
                return Err(OdbcError::UnsupportedFeature(
                    "Native SQL Server BCP path only applies to SQL Server connections".to_string(),
                ));
            }

            sqlserver_bcp::execute_native_bcp(conn_str, payload, self.batch_size)
        }

        #[cfg(not(windows))]
        {
            let _ = (payload, conn_str);
            Err(OdbcError::UnsupportedFeature(
                "Native SQL Server BCP is currently supported only on Windows builds".to_string(),
            ))
        }
    }

    fn is_sql_server_conn_str(conn_str: &str) -> bool {
        let lowered = conn_str.to_lowercase();
        lowered.contains("sql server")
            || lowered.contains("odbc driver 17 for sql server")
            || lowered.contains("odbc driver 18 for sql server")
            || (lowered.contains("server=") && lowered.contains("database="))
    }

    fn is_native_bcp_runtime_enabled() -> bool {
        std::env::var("ODBC_ENABLE_UNSTABLE_NATIVE_BCP")
            .ok()
            .as_deref()
            .map(str::trim)
            .is_some_and(|raw| matches!(raw, "1" | "true" | "TRUE" | "yes" | "YES"))
    }

    fn validate_payload(payload: &BulkInsertPayload) -> Result<()> {
        if payload.table.trim().is_empty() {
            return Err(OdbcError::ValidationError(
                "Bulk insert payload table cannot be empty".to_string(),
            ));
        }
        if payload.columns.is_empty() {
            return Err(OdbcError::ValidationError(
                "Bulk insert payload must contain at least one column".to_string(),
            ));
        }
        if payload.column_data.len() != payload.columns.len() {
            return Err(OdbcError::ValidationError(format!(
                "Bulk insert payload column_data count ({}) does not match columns count ({})",
                payload.column_data.len(),
                payload.columns.len(),
            )));
        }

        let row_count = payload.row_count as usize;
        for (idx, data) in payload.column_data.iter().enumerate() {
            let actual_rows = Self::column_row_count(data);
            if actual_rows != row_count {
                return Err(OdbcError::ValidationError(format!(
                    "Bulk insert payload column '{}' (index {}) has {} rows, expected {}",
                    payload.columns[idx].name, idx, actual_rows, row_count,
                )));
            }
        }

        Ok(())
    }

    fn column_row_count(data: &crate::protocol::BulkColumnData) -> usize {
        match data {
            crate::protocol::BulkColumnData::I32 { values, .. } => values.len(),
            crate::protocol::BulkColumnData::I64 { values, .. } => values.len(),
            crate::protocol::BulkColumnData::Text { rows, .. } => rows.len(),
            crate::protocol::BulkColumnData::Binary { rows, .. } => rows.len(),
            crate::protocol::BulkColumnData::Timestamp { values, .. } => values.len(),
        }
    }

    fn should_fallback_to_array_binding(error: &OdbcError) -> bool {
        match error {
            OdbcError::ValidationError(_) => false,
            OdbcError::UnsupportedFeature(_) => true,
            OdbcError::InternalError(_) => true,
            OdbcError::OdbcApi(_) => true,
            OdbcError::Structured { .. } => true,
            OdbcError::PoolError(_) => true,
            OdbcError::InvalidHandle(_) => true,
            OdbcError::EmptyConnectionString => true,
            OdbcError::EnvironmentNotInitialized => true,
        }
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
            _conn_str: Option<&str>,
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

    #[cfg(feature = "sqlserver-bcp")]
    #[test]
    fn test_validate_payload_rejects_mismatched_column_lengths() {
        let payload = BulkInsertPayload {
            table: "dbo.test_table".to_string(),
            columns: vec![crate::protocol::BulkColumnSpec {
                name: "id".to_string(),
                col_type: crate::protocol::BulkColumnType::I32,
                nullable: false,
                max_len: 4,
            }],
            row_count: 2,
            column_data: vec![crate::protocol::BulkColumnData::I32 {
                values: vec![1],
                null_bitmap: None,
            }],
        };

        let err = BulkCopyExecutor::validate_payload(&payload).unwrap_err();
        assert!(matches!(err, OdbcError::ValidationError(_)));
    }

    #[cfg(feature = "sqlserver-bcp")]
    #[test]
    fn test_validate_payload_accepts_consistent_payload() {
        let payload = BulkInsertPayload {
            table: "dbo.test_table".to_string(),
            columns: vec![
                crate::protocol::BulkColumnSpec {
                    name: "id".to_string(),
                    col_type: crate::protocol::BulkColumnType::I32,
                    nullable: false,
                    max_len: 4,
                },
                crate::protocol::BulkColumnSpec {
                    name: "name".to_string(),
                    col_type: crate::protocol::BulkColumnType::Text,
                    nullable: true,
                    max_len: 16,
                },
            ],
            row_count: 2,
            column_data: vec![
                crate::protocol::BulkColumnData::I32 {
                    values: vec![1, 2],
                    null_bitmap: None,
                },
                crate::protocol::BulkColumnData::Text {
                    rows: vec![b"a".to_vec(), b"b".to_vec()],
                    max_len: 16,
                    null_bitmap: None,
                },
            ],
        };

        assert!(BulkCopyExecutor::validate_payload(&payload).is_ok());
    }

    #[cfg(feature = "sqlserver-bcp")]
    #[test]
    fn test_should_fallback_to_array_binding_rules() {
        assert!(!BulkCopyExecutor::should_fallback_to_array_binding(
            &OdbcError::ValidationError("bad payload".to_string())
        ));
        assert!(BulkCopyExecutor::should_fallback_to_array_binding(
            &OdbcError::UnsupportedFeature("not available".to_string())
        ));
    }

    #[cfg(feature = "sqlserver-bcp")]
    #[test]
    fn test_native_bcp_runtime_enabled_default_false() {
        // This test only verifies default behavior when env var is absent.
        unsafe {
            std::env::remove_var("ODBC_ENABLE_UNSTABLE_NATIVE_BCP");
        }
        assert!(!BulkCopyExecutor::is_native_bcp_runtime_enabled());
    }
}

use crate::error::{OdbcError, Result};

const XA_SQLSERVER_DTC_ACTIVE_FALLBACK: &str = "\
XA / 2PC on SQL Server: lifecycle support is active through the `xa-dtc` \
MSDTC path, but this operation reached the SQL fallback. Advanced MSDTC \
recovery / Reenlist is outside the crate; see \
doc/Features/PENDING_IMPLEMENTATIONS.md section 2.1.";
const XA_SQLSERVER_DTC_REQUIRED: &str = "\
XA / 2PC on SQL Server requires MSDTC enlistment via Windows COM \
(SQLSetConnectAttr(SQL_ATTR_ENLIST_IN_DTC, ITransaction*)). Build with \
`--features xa-dtc` on a Windows host with MSDTC enabled to activate the \
integration; see doc/Features/PENDING_IMPLEMENTATIONS.md section 2.1 for \
prerequisites.";

/// Unenlist wrapper so `end()` / one-phase / rollback can call MSDTC
/// unenlist without duplicating `#[cfg]`.
pub(crate) fn mssql_mdtc_unenlist(conn: &mut odbc_api::Connection<'static>) -> Result<()> {
    #[cfg(all(target_os = "windows", feature = "xa-dtc"))]
    {
        crate::engine::xa_dtc::unenlist_from_dtc(conn)
    }
    #[cfg(not(all(target_os = "windows", feature = "xa-dtc")))]
    {
        let _ = conn;
        Ok(())
    }
}

pub(crate) fn unsupported_sqlserver() -> OdbcError {
    // SQL Server MSDTC lifecycle is handled before the SQL-emitter matrix when
    // built on Windows with `xa-dtc`. Reaching this fallback means either the
    // feature/platform is unavailable or a recovery-style call has no in-crate
    // MSDTC mapping.
    if cfg!(all(target_os = "windows", feature = "xa-dtc")) {
        OdbcError::UnsupportedFeature(XA_SQLSERVER_DTC_ACTIVE_FALLBACK.to_string())
    } else {
        OdbcError::UnsupportedFeature(XA_SQLSERVER_DTC_REQUIRED.to_string())
    }
}

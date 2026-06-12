use crate::error::{OdbcError, Result};
use odbc_api::sys::{HDbc, Handle, HandleType, SQLDisconnect, SQLFreeHandle, SqlReturn, WChar};

pub(crate) fn ensure_success(rc: SqlReturn, step: &str) -> Result<()> {
    if rc == SqlReturn::SUCCESS || rc == SqlReturn::SUCCESS_WITH_INFO {
        Ok(())
    } else {
        Err(OdbcError::InternalError(format!(
            "{step} failed with SQL return code {}",
            rc.0
        )))
    }
}

pub(crate) fn to_wide_nul(input: &str) -> Vec<WChar> {
    input.encode_utf16().chain(std::iter::once(0)).collect()
}

pub(crate) fn free_handle_silent(handle_type: HandleType, handle: Handle) {
    if !handle.0.is_null() {
        let _ = unsafe {
            // SAFETY: Best-effort cleanup. Handle may already be partially initialized.
            SQLFreeHandle(handle_type, handle)
        };
    }
}

pub(crate) fn disconnect_and_free_silent(dbc_handle: HDbc, dbc: Handle, env: Handle) {
    if !dbc_handle.0.is_null() {
        let _ = unsafe {
            // SAFETY: Best-effort disconnect on valid connection handle.
            SQLDisconnect(dbc_handle)
        };
    }
    free_handle_silent(HandleType::Dbc, dbc);
    free_handle_silent(HandleType::Env, env);
}

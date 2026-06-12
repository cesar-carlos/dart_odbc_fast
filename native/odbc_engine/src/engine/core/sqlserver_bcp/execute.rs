use crate::error::{OdbcError, Result};
use crate::protocol::BulkInsertPayload;
use odbc_api::sys::{
    ConnectionAttribute, DriverConnectOption, Handle, HandleType, SQLAllocHandle,
    SQLDriverConnectW, SQLSetConnectAttr, SQLSetEnvAttr, SmallInt, NTSL,
};
use std::ffi::c_void;

use super::bound_column::BoundColumnRef;
use super::helpers::{disconnect_and_free_silent, ensure_success, free_handle_silent, to_wide_nul};
use super::library::{
    get_symbol, load_bcp_library, BcpBindFn, BcpColLenFn, BcpDoneFn, BcpInitWFn, BcpSendRowFn,
};

const SQL_COPT_SS_BCP: i32 = 1219;
const SQL_BCP_ON: i32 = 1;
const DB_IN: i32 = 1;

pub(crate) fn run_native_bcp(
    conn_str: &str,
    payload: &BulkInsertPayload,
    _batch_size: usize,
    bound_columns: &mut [BoundColumnRef<'_>],
    row_count: usize,
) -> Result<usize> {
    let lib = load_bcp_library()?;
    let bcp_init_w = get_symbol::<BcpInitWFn>(&lib, &[b"bcp_initW\0"])?;
    let bcp_bind = get_symbol::<BcpBindFn>(&lib, &[b"bcp_bind\0"])?;
    let bcp_collen = get_symbol::<BcpColLenFn>(&lib, &[b"bcp_collen\0"])?;
    let bcp_sendrow = get_symbol::<BcpSendRowFn>(&lib, &[b"bcp_sendrow\0"])?;
    let bcp_done = get_symbol::<BcpDoneFn>(&lib, &[b"bcp_done\0"])?;

    let mut env: Handle = Handle::null();
    let mut dbc: Handle = Handle::null();

    let env_alloc = unsafe {
        // SAFETY: Arguments follow ODBC contract; output pointer is valid local storage.
        SQLAllocHandle(HandleType::Env, Handle::null(), &mut env)
    };
    ensure_success(env_alloc, "SQLAllocHandle(SQL_HANDLE_ENV)")?;
    let env_handle = env.as_henv();

    let version_set = unsafe {
        // SAFETY: ODBC version attribute is required before allocating connection handles.
        SQLSetEnvAttr(
            env_handle,
            odbc_api::sys::EnvironmentAttribute::OdbcVersion,
            odbc_api::sys::AttrOdbcVersion::Odbc3.into(),
            0,
        )
    };
    if let Err(err) = ensure_success(version_set, "SQLSetEnvAttr(SQL_ATTR_ODBC_VERSION)") {
        free_handle_silent(HandleType::Env, env);
        return Err(err);
    }

    let dbc_alloc = unsafe {
        // SAFETY: Environment handle is valid.
        SQLAllocHandle(HandleType::Dbc, env, &mut dbc)
    };
    if let Err(err) = ensure_success(dbc_alloc, "SQLAllocHandle(SQL_HANDLE_DBC)") {
        free_handle_silent(HandleType::Env, env);
        return Err(err);
    }
    let dbc_handle = dbc.as_hdbc();

    let bcp_attr_set = unsafe {
        // SAFETY: Must be called before connect. Value follows SQLSetConnectAttr integer contract.
        SQLSetConnectAttr(
            dbc_handle,
            ConnectionAttribute(SQL_COPT_SS_BCP),
            SQL_BCP_ON as usize as *mut c_void,
            odbc_api::sys::IS_INTEGER,
        )
    };
    if let Err(err) = ensure_success(bcp_attr_set, "SQLSetConnectAttr(SQL_COPT_SS_BCP)") {
        disconnect_and_free_silent(dbc_handle, dbc, env);
        return Err(err);
    }

    let conn_wide = to_wide_nul(conn_str);
    let connected = unsafe {
        // SAFETY: Input string is NUL-terminated UTF-16, pointers are valid.
        SQLDriverConnectW(
            dbc_handle,
            std::ptr::null_mut(),
            conn_wide.as_ptr(),
            NTSL as SmallInt,
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            DriverConnectOption::NoPrompt,
        )
    };
    if let Err(err) = ensure_success(connected, "SQLDriverConnectW") {
        disconnect_and_free_silent(dbc_handle, dbc, env);
        return Err(err);
    }

    let table_wide = to_wide_nul(payload.table.as_str());
    let init_rc = unsafe {
        // SAFETY: BCP handle connected and BCP-enabled. Table pointer is valid NUL-terminated UTF-16.
        bcp_init_w(
            dbc_handle,
            table_wide.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            DB_IN,
        )
    };
    if init_rc == 0 {
        disconnect_and_free_silent(dbc_handle, dbc, env);
        return Err(OdbcError::InternalError(
            "bcp_initW failed for native BCP execution".to_string(),
        ));
    }

    for (idx, col) in bound_columns.iter_mut().enumerate() {
        let (p_data, cb_data, e_data_type) = col.bind_args_mut();
        let bind_rc = unsafe {
            // SAFETY: Pointers target stable per-column memory kept alive for all rows.
            bcp_bind(
                dbc_handle,
                p_data,
                0,
                cb_data,
                std::ptr::null(),
                0,
                e_data_type,
                (idx + 1) as i32,
            )
        };
        if bind_rc == 0 {
            disconnect_and_free_silent(dbc_handle, dbc, env);
            return Err(OdbcError::InternalError(format!(
                "bcp_bind failed for native BCP execution at column {}",
                idx + 1
            )));
        }
    }

    for row_idx in 0..row_count {
        for (idx, col) in bound_columns.iter_mut().enumerate() {
            col.write_row(row_idx);
            let collen = col.row_collen_for_bcp(row_idx);
            let collen_rc = unsafe {
                // SAFETY: Column index is 1-based and valid for the established binding layout.
                // bcp_collen must be called for every row to set the correct length (or SQL_NULL_DATA).
                bcp_collen(dbc_handle, collen, (idx + 1) as i32)
            };
            if collen_rc == 0 {
                disconnect_and_free_silent(dbc_handle, dbc, env);
                return Err(OdbcError::InternalError(format!(
                    "bcp_collen failed during native BCP execution at row {} column {}",
                    row_idx,
                    idx + 1
                )));
            }
        }
        let send_rc = unsafe {
            // SAFETY: `bcp_bind` already bound row memory and we only update bound storage.
            bcp_sendrow(dbc_handle)
        };
        if send_rc == 0 {
            disconnect_and_free_silent(dbc_handle, dbc, env);
            return Err(OdbcError::InternalError(format!(
                "bcp_sendrow failed at row {} during native BCP execution",
                row_idx
            )));
        }
    }

    let done_rows = unsafe {
        // SAFETY: Finalizes BCP session on a valid connected BCP handle.
        bcp_done(dbc_handle)
    };
    if done_rows < 0 {
        disconnect_and_free_silent(dbc_handle, dbc, env);
        return Err(OdbcError::InternalError(
            "bcp_done failed during native BCP execution".to_string(),
        ));
    }

    disconnect_and_free_silent(dbc_handle, dbc, env);
    Ok(done_rows as usize)
}

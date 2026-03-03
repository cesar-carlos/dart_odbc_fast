//! SQL Server native BCP (Bulk Copy Program) implementation.
//!
//! # DLL Compatibility
//!
//! - **sqlncli11.dll** (SQL Server Native Client 11.0): Fully compatible with `bcp_initW` and all BCP functions.
//! - **msodbcsql17.dll** / **msodbcsql18.dll** (Microsoft ODBC Driver 17/18): `bcp_initW` fails with rc=0 (known issue).
//!
//! We prioritize `sqlncli11.dll` for BCP operations. If unavailable, we attempt modern drivers but may fall back to ArrayBinding.
//!
//! # bcp_collen Usage
//!
//! `bcp_collen` sets the column length for **all subsequent rows** until called again. For nullable columns:
//! - Must call `bcp_collen(SQL_NULL_DATA)` for null rows
//! - Must call `bcp_collen(actual_size)` for non-null rows after a null row
//! - Safest approach: call `bcp_collen` for **every row** to avoid state persistence bugs

use crate::error::{OdbcError, Result};
use crate::protocol::bulk_insert::is_null;
use crate::protocol::{BulkColumnData, BulkColumnType, BulkInsertPayload};
use libloading::Library;
use odbc_api::sys::{
    ConnectionAttribute, DriverConnectOption, HDbc, Handle, HandleType, SQLAllocHandle,
    SQLDisconnect, SQLDriverConnectW, SQLFreeHandle, SQLSetConnectAttr, SQLSetEnvAttr, SmallInt,
    SqlReturn, WChar, IS_INTEGER, NTSL,
};
use std::ffi::c_void;

const CANDIDATE_LIBRARIES: &[&str] = &["sqlncli11.dll", "msodbcsql17.dll", "msodbcsql18.dll"];

const REQUIRED_SYMBOL_SETS: &[&[&[u8]]] = &[
    &[b"bcp_initW\0", b"bcp_init\0"],
    &[b"bcp_bind\0"],
    &[b"bcp_collen\0"],
    &[b"bcp_sendrow\0"],
    &[b"bcp_done\0"],
];

const SQL_COPT_SS_BCP: i32 = 1219;
const SQL_BCP_ON: i32 = 1;
const DB_IN: i32 = 1;
const SQLINT4: i32 = 56;
const SQLINT8: i32 = 127;
const SQL_NULL_DATA: i32 = -1;

type BcpInitWFn = unsafe extern "system" fn(
    hdbc: HDbc,
    sz_table: *const WChar,
    sz_data_file: *const WChar,
    sz_error_file: *const WChar,
    e_direction: i32,
) -> i32;
type BcpBindFn = unsafe extern "system" fn(
    hdbc: HDbc,
    p_data: *const u8,
    cb_indicator: i32,
    cb_data: i32,
    p_term: *const u8,
    cb_term: i32,
    e_data_type: i32,
    idx_server_col: i32,
) -> i32;
type BcpColLenFn = unsafe extern "system" fn(hdbc: HDbc, cb_data: i32, idx_server_col: i32) -> i32;
type BcpSendRowFn = unsafe extern "system" fn(hdbc: HDbc) -> i32;
type BcpDoneFn = unsafe extern "system" fn(hdbc: HDbc) -> i32;

enum BoundColumnRef<'a> {
    I32 {
        values: &'a [i32],
        null_bitmap: Option<&'a [u8]>,
        cell: std::mem::MaybeUninit<i32>,
    },
    I64 {
        values: &'a [i64],
        null_bitmap: Option<&'a [u8]>,
        cell: std::mem::MaybeUninit<i64>,
    },
}

impl<'a> BoundColumnRef<'a> {
    fn len(&self) -> usize {
        match self {
            BoundColumnRef::I32 { values, .. } => values.len(),
            BoundColumnRef::I64 { values, .. } => values.len(),
        }
    }

    fn bind_args_mut(&mut self) -> (*const u8, i32, i32) {
        match self {
            BoundColumnRef::I32 { cell, .. } => (
                cell.as_mut_ptr().cast::<u8>(),
                std::mem::size_of::<i32>() as i32,
                SQLINT4,
            ),
            BoundColumnRef::I64 { cell, .. } => (
                cell.as_mut_ptr().cast::<u8>(),
                std::mem::size_of::<i64>() as i32,
                SQLINT8,
            ),
        }
    }

    fn write_row(&mut self, row_idx: usize) {
        match self {
            BoundColumnRef::I32 {
                values,
                null_bitmap,
                cell,
            } => {
                let value = if null_bitmap.is_some_and(|bm| is_null(bm, row_idx)) {
                    0
                } else {
                    values[row_idx]
                };
                let _ = cell.write(value);
            }
            BoundColumnRef::I64 {
                values,
                null_bitmap,
                cell,
            } => {
                let value = if null_bitmap.is_some_and(|bm| is_null(bm, row_idx)) {
                    0
                } else {
                    values[row_idx]
                };
                let _ = cell.write(value);
            }
        }
    }

    fn row_collen_for_bcp(&self, row_idx: usize) -> i32 {
        match self {
            BoundColumnRef::I32 { null_bitmap, .. } => {
                if null_bitmap.is_some_and(|bm| is_null(bm, row_idx)) {
                    SQL_NULL_DATA
                } else {
                    std::mem::size_of::<i32>() as i32
                }
            }
            BoundColumnRef::I64 { null_bitmap, .. } => {
                if null_bitmap.is_some_and(|bm| is_null(bm, row_idx)) {
                    SQL_NULL_DATA
                } else {
                    std::mem::size_of::<i64>() as i32
                }
            }
        }
    }
}

pub fn probe_native_bcp_support() -> Result<()> {
    let mut load_errors: Vec<String> = Vec::new();

    for candidate in CANDIDATE_LIBRARIES {
        match probe_library(candidate) {
            Ok(()) => return Ok(()),
            Err(err) => load_errors.push(format!("{candidate}: {err}")),
        }
    }

    Err(OdbcError::UnsupportedFeature(format!(
        "Unable to load SQL Server BCP libraries from PATH. Tried: {}",
        load_errors.join(" | ")
    )))
}

pub fn execute_native_bcp(
    conn_str: &str,
    payload: &BulkInsertPayload,
    _batch_size: usize,
) -> Result<usize> {
    if payload.columns.is_empty() {
        return Ok(0);
    }
    let mut bound_columns = build_bound_columns(payload)?;
    let row_count = payload.row_count as usize;
    for (idx, col) in bound_columns.iter().enumerate() {
        if col.len() != row_count {
            return Err(OdbcError::ValidationError(format!(
                "Native BCP payload column {} has {} rows, expected {}",
                idx,
                col.len(),
                row_count
            )));
        }
    }

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
            IS_INTEGER,
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

fn load_bcp_library() -> Result<Library> {
    let mut errors: Vec<String> = Vec::new();
    for candidate in CANDIDATE_LIBRARIES {
        let try_load = unsafe {
            // SAFETY: Dynamic loading for optional SQL Server BCP runtime.
            Library::new(candidate)
        };
        match try_load {
            Ok(lib) => return Ok(lib),
            Err(err) => errors.push(format!("{candidate}: {err}")),
        }
    }
    Err(OdbcError::UnsupportedFeature(format!(
        "Unable to load SQL Server BCP library. Tried: {}",
        errors.join(" | ")
    )))
}

fn build_bound_columns<'a>(payload: &'a BulkInsertPayload) -> Result<Vec<BoundColumnRef<'a>>> {
    if payload.column_data.len() != payload.columns.len() {
        return Err(OdbcError::ValidationError(format!(
            "Native BCP payload mismatch: {} columns vs {} data blocks",
            payload.columns.len(),
            payload.column_data.len()
        )));
    }

    payload
        .columns
        .iter()
        .zip(payload.column_data.iter())
        .map(|(spec, data)| match (&spec.col_type, data) {
            (
                BulkColumnType::I32,
                BulkColumnData::I32 {
                    values,
                    null_bitmap,
                },
            ) => Ok(BoundColumnRef::I32 {
                values: values.as_slice(),
                null_bitmap: validate_null_bitmap(
                    null_bitmap.as_deref(),
                    values.len(),
                    spec.name.as_str(),
                )?,
                cell: std::mem::MaybeUninit::uninit(),
            }),
            (
                BulkColumnType::I64,
                BulkColumnData::I64 {
                    values,
                    null_bitmap,
                },
            ) => Ok(BoundColumnRef::I64 {
                values: values.as_slice(),
                null_bitmap: validate_null_bitmap(
                    null_bitmap.as_deref(),
                    values.len(),
                    spec.name.as_str(),
                )?,
                cell: std::mem::MaybeUninit::uninit(),
            }),
            (BulkColumnType::I32 | BulkColumnType::I64, _) => {
                Err(OdbcError::UnsupportedFeature(format!(
                    "Native BCP currently requires matching payload type for '{}'",
                    spec.name
                )))
            }
            _ => Err(OdbcError::UnsupportedFeature(format!(
                "Native BCP currently supports only I32/I64 columns; '{}' uses {:?}",
                spec.name, spec.col_type
            ))),
        })
        .collect()
}

fn validate_null_bitmap<'a>(
    bitmap: Option<&'a [u8]>,
    row_count: usize,
    column_name: &str,
) -> Result<Option<&'a [u8]>> {
    let Some(bitmap) = bitmap else {
        return Ok(None);
    };
    let expected = row_count.div_ceil(8);
    if bitmap.len() != expected {
        return Err(OdbcError::ValidationError(format!(
            "Native BCP null bitmap size mismatch for column '{}': got {}, expected {}",
            column_name,
            bitmap.len(),
            expected
        )));
    }
    Ok(Some(bitmap))
}

fn probe_library(library_name: &str) -> Result<()> {
    // SAFETY: Loading a dynamic library and probing symbol addresses is required for
    // runtime capability detection. We do not call symbols here, only check existence.
    let lib = unsafe { Library::new(library_name) }.map_err(|err| {
        OdbcError::UnsupportedFeature(format!("failed to load library '{library_name}': {err}"))
    })?;

    for symbol_set in REQUIRED_SYMBOL_SETS {
        if !has_any_symbol(&lib, symbol_set) {
            let expected = symbol_set
                .iter()
                .map(|name| trim_symbol_name(name))
                .collect::<Vec<_>>()
                .join(" or ");
            return Err(OdbcError::UnsupportedFeature(format!(
                "library '{library_name}' missing required symbol(s): {expected}"
            )));
        }
    }

    Ok(())
}

fn get_symbol<T>(lib: &Library, names: &[&[u8]]) -> Result<T>
where
    T: Copy,
{
    for name in names {
        let symbol = unsafe {
            // SAFETY: Symbol is resolved from loaded library; caller chooses signature.
            lib.get::<T>(name)
        };
        if let Ok(sym) = symbol {
            return Ok(*sym);
        }
    }
    Err(OdbcError::UnsupportedFeature(format!(
        "Required BCP symbol not found: {}",
        names
            .iter()
            .map(|n| trim_symbol_name(n))
            .collect::<Vec<_>>()
            .join(" or ")
    )))
}

fn ensure_success(rc: SqlReturn, step: &str) -> Result<()> {
    if rc == SqlReturn::SUCCESS || rc == SqlReturn::SUCCESS_WITH_INFO {
        Ok(())
    } else {
        Err(OdbcError::InternalError(format!(
            "{step} failed with SQL return code {}",
            rc.0
        )))
    }
}

fn has_any_symbol(lib: &Library, symbols: &[&[u8]]) -> bool {
    symbols.iter().any(|symbol| {
        // SAFETY: We only test for symbol presence and never call through the pointer.
        unsafe { lib.get::<*const ()>(symbol).is_ok() }
    })
}

fn trim_symbol_name(symbol: &[u8]) -> String {
    let no_nul = symbol.strip_suffix(&[0]).unwrap_or(symbol);
    String::from_utf8_lossy(no_nul).to_string()
}

fn to_wide_nul(input: &str) -> Vec<WChar> {
    input.encode_utf16().chain(std::iter::once(0)).collect()
}

fn free_handle_silent(handle_type: HandleType, handle: Handle) {
    if !handle.0.is_null() {
        let _ = unsafe {
            // SAFETY: Best-effort cleanup. Handle may already be partially initialized.
            SQLFreeHandle(handle_type, handle)
        };
    }
}

fn disconnect_and_free_silent(dbc_handle: HDbc, dbc: Handle, env: Handle) {
    if !dbc_handle.0.is_null() {
        let _ = unsafe {
            // SAFETY: Best-effort disconnect on valid connection handle.
            SQLDisconnect(dbc_handle)
        };
    }
    free_handle_silent(HandleType::Dbc, dbc);
    free_handle_silent(HandleType::Env, env);
}

#[cfg(test)]
mod tests {
    use super::{build_bound_columns, to_wide_nul, trim_symbol_name};
    use crate::protocol::{BulkColumnData, BulkColumnSpec, BulkColumnType, BulkInsertPayload};

    #[test]
    fn test_trim_symbol_name() {
        assert_eq!(trim_symbol_name(b"bcp_initW\0"), "bcp_initW");
    }

    #[test]
    fn test_to_wide_nul_appends_terminator() {
        let wide = to_wide_nul("abc");
        assert_eq!(wide.last(), Some(&0));
    }

    #[test]
    fn test_build_bound_columns_accepts_nullable_numeric() {
        let payload = BulkInsertPayload {
            table: "dbo.t".to_string(),
            columns: vec![
                BulkColumnSpec {
                    name: "id".to_string(),
                    col_type: BulkColumnType::I32,
                    nullable: true,
                    max_len: 0,
                },
                BulkColumnSpec {
                    name: "score".to_string(),
                    col_type: BulkColumnType::I64,
                    nullable: true,
                    max_len: 0,
                },
            ],
            row_count: 3,
            column_data: vec![
                BulkColumnData::I32 {
                    values: vec![1, 0, 3],
                    null_bitmap: Some(vec![0b010]),
                },
                BulkColumnData::I64 {
                    values: vec![10, 0, 30],
                    null_bitmap: Some(vec![0b010]),
                },
            ],
        };

        let cols = build_bound_columns(&payload).expect("columns should be accepted");
        assert_eq!(cols.len(), 2);
        assert_eq!(cols[0].len(), 3);
        assert_eq!(cols[1].len(), 3);
    }

    #[test]
    fn test_build_bound_columns_rejects_invalid_null_bitmap_size() {
        let payload = BulkInsertPayload {
            table: "dbo.t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "id".to_string(),
                col_type: BulkColumnType::I64,
                nullable: true,
                max_len: 0,
            }],
            row_count: 9,
            column_data: vec![BulkColumnData::I64 {
                values: vec![0; 9],
                null_bitmap: Some(vec![0b0000_0001]),
            }],
        };

        let message = match build_bound_columns(&payload) {
            Ok(_) => panic!("bitmap size should be validated"),
            Err(err) => err.to_string(),
        };
        assert!(message.contains("null bitmap size mismatch"));
    }
}

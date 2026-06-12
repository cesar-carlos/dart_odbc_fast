use crate::error::{OdbcError, Result};
use libloading::Library;

pub(crate) const CANDIDATE_LIBRARIES: &[&str] =
    &["sqlncli11.dll", "msodbcsql17.dll", "msodbcsql18.dll"];

const REQUIRED_SYMBOL_SETS: &[&[&[u8]]] = &[
    &[b"bcp_initW\0", b"bcp_init\0"],
    &[b"bcp_bind\0"],
    &[b"bcp_collen\0"],
    &[b"bcp_sendrow\0"],
    &[b"bcp_done\0"],
];

pub(crate) type BcpInitWFn = unsafe extern "system" fn(
    hdbc: odbc_api::sys::HDbc,
    sz_table: *const odbc_api::sys::WChar,
    sz_data_file: *const odbc_api::sys::WChar,
    sz_error_file: *const odbc_api::sys::WChar,
    e_direction: i32,
) -> i32;
pub(crate) type BcpBindFn = unsafe extern "system" fn(
    hdbc: odbc_api::sys::HDbc,
    p_data: *const u8,
    cb_indicator: i32,
    cb_data: i32,
    p_term: *const u8,
    cb_term: i32,
    e_data_type: i32,
    idx_server_col: i32,
) -> i32;
pub(crate) type BcpColLenFn =
    unsafe extern "system" fn(hdbc: odbc_api::sys::HDbc, cb_data: i32, idx_server_col: i32) -> i32;
pub(crate) type BcpSendRowFn = unsafe extern "system" fn(hdbc: odbc_api::sys::HDbc) -> i32;
pub(crate) type BcpDoneFn = unsafe extern "system" fn(hdbc: odbc_api::sys::HDbc) -> i32;

pub(crate) fn load_bcp_library() -> Result<Library> {
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

pub(crate) fn probe_library(library_name: &str) -> Result<()> {
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

pub(crate) fn get_symbol<T>(lib: &Library, names: &[&[u8]]) -> Result<T>
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

fn has_any_symbol(lib: &Library, symbols: &[&[u8]]) -> bool {
    symbols.iter().any(|symbol| {
        // SAFETY: We only test for symbol presence and never call through the pointer.
        unsafe { lib.get::<*const ()>(symbol).is_ok() }
    })
}

pub(crate) fn trim_symbol_name(symbol: &[u8]) -> String {
    let no_nul = symbol.strip_suffix(&[0]).unwrap_or(symbol);
    String::from_utf8_lossy(no_nul).to_string()
}

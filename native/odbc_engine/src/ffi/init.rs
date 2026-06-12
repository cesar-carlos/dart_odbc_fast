// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use super::connection::validate_connection_string_format;
use super::global::*;

use crate::async_bridge;
use crate::engine::OdbcEnvironment;
use crate::versioning::{abi_version::AbiVersion, api_version::ApiVersion};
use log::LevelFilter;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_uint};
use std::sync::{Arc, Mutex};

/// Initialize ODBC environment and async runtime
/// Returns: 0 on success, non-zero error code on failure
#[no_mangle]
pub extern "C" fn odbc_init() -> c_int {
    crate::ffi_guard_int!({
        if async_bridge::init_runtime().is_err() {
            if let Some(mut state) = try_lock_global_state() {
                let detail = async_bridge::runtime_init_error()
                    .map(str::to_owned)
                    .unwrap_or_else(|| "init_runtime failed".to_string());
                set_error(&mut state, detail);
            }
            return 1;
        }

        let Some(mut state) = try_lock_global_state() else {
            // Mutex is poisoned - critical error
            return -1;
        };

        if state.env.is_some() {
            return 0;
        }

        let env = OdbcEnvironment::new();
        match env.init() {
            Ok(_) => {
                state.env = Some(Arc::new(Mutex::new(env)));
                0
            }
            Err(e) => {
                set_error(&mut state, format!("odbc_init failed: {}", e));
                1
            }
        }
    })
}

/// Set log level for the native engine (0=Off, 1=Error, 2=Warn, 3=Info, 4=Debug).
///
/// Affects the `log` crate's max level filter. A logger (e.g. env_logger) must be
/// initialized by the host for output to appear. Returns 0 on success.
#[no_mangle]
pub extern "C" fn odbc_set_log_level(level: c_int) -> c_int {
    crate::ffi_guard_int!({
        let filter = match level {
            0 => LevelFilter::Off,
            1 => LevelFilter::Error,
            2 => LevelFilter::Warn,
            3 => LevelFilter::Info,
            4 => LevelFilter::Debug,
            5 => LevelFilter::Trace,
            _ => LevelFilter::Off,
        };
        log::set_max_level(filter);
        0
    })
}

/// Returns engine version as JSON for client compatibility checks.
///
/// Output format: `{"api":"<cargo-package-version>","abi":"<abi-major>.<abi-minor>"}` (UTF-8).
/// - **api**: package version from Cargo.toml.
/// - **abi**: current FFI contract version.
///
/// Returns: 0 on success; -1 if buffer or out_written is null; -2 if buffer too small.
#[no_mangle]
pub extern "C" fn odbc_get_version(
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if buffer.is_null() || out_written.is_null() {
            return -1;
        }

        let json = format!(
            r#"{{"api":"{}","abi":"{}"}}"#,
            ApiVersion::current(),
            AbiVersion::current()
        );
        let bytes = json.as_bytes();

        if bytes.len() > buffer_len as usize {
            set_out_written_needed(out_written, bytes.len());
            return -2;
        }

        unsafe {
            // SAFETY: `buffer` and `out_written` are non-null (checked above);
            // `bytes.len() <= buffer_len` (checked above); `buffer` is writable
            // for `buffer_len` bytes per the caller's FFI contract.
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, bytes.len());
            *out_written = bytes.len() as c_uint;
        }
        0
    })
}

/// Validates connection string format without connecting.
///
/// Checks: non-empty, valid UTF-8, at least one key=value pair, balanced braces.
/// Does not verify driver availability or server reachability.
/// Returns: 0 if valid; -1 if invalid (error message written to error_buffer).
#[no_mangle]
pub extern "C" fn odbc_validate_connection_string(
    conn_str: *const c_char,
    error_buffer: *mut u8,
    error_buffer_len: c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if conn_str.is_null() {
            return -1;
        }

        // SAFETY: `conn_str` is non-null (checked above); caller guarantees a valid
        // NUL-terminated C string for the duration of this FFI call.
        let s = unsafe { CStr::from_ptr(conn_str) };
        let conn_str_rust = match s.to_str() {
            Ok(x) => x.trim(),
            Err(_) => {
                if !error_buffer.is_null() && error_buffer_len > 0 {
                    let msg = b"Invalid UTF-8";
                    let n = msg.len().min(error_buffer_len as usize - 1);
                    // SAFETY: `error_buffer` is non-null with `error_buffer_len > 0`;
                    // `n < error_buffer_len` so the copy and trailing NUL fit.
                    unsafe {
                        std::ptr::copy_nonoverlapping(msg.as_ptr(), error_buffer, n);
                        *error_buffer.add(n) = 0;
                    }
                }
                return -1;
            }
        };

        let err = validate_connection_string_format(conn_str_rust);

        if let Some(msg) = err {
            if error_buffer.is_null() || error_buffer_len == 0 {
                return -1;
            }
            let bytes = msg.as_bytes();
            let needed = bytes.len() + 1;
            if (error_buffer_len as usize) < needed {
                return -1;
            }
            // SAFETY: `error_buffer` is non-null with `error_buffer_len >= needed`
            // (checked above); copy fits and the trailing NUL is within bounds.
            unsafe {
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), error_buffer, bytes.len());
                *error_buffer.add(bytes.len()) = 0;
            }
            return -1;
        }

        0
    })
}

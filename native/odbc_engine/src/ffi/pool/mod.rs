// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

mod alloc_id;
mod checkout_checkin;
mod metrics;

use alloc_id::pool_create_inner;
use checkout_checkin::{checkin_pooled_connection, checkout_pooled_connection, close_pool};
use metrics::{pool_get_state, pool_get_state_json, pool_health_check, pool_set_size};

use crate::ffi::guard;

use std::os::raw::{c_char, c_int, c_uint};
use std::time::Duration;

/// Create connection pool.
#[no_mangle]
pub extern "C" fn odbc_pool_create(conn_str: *const c_char, max_size: c_uint) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        if conn_str.is_null() {
            return 0;
        }

        // SAFETY: `conn_str` is non-null (checked above); caller guarantees a
        // valid NUL-terminated C string for the duration of this call.
        let Some(c_str) = (unsafe { guard::ptr_to_cstr(conn_str) }) else {
            return 0;
        };
        let conn_str_rust = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return 0,
        };

        pool_create_inner(conn_str_rust, max_size, crate::pool::PoolOptions::default())
    })
}

/// Create a connection pool with explicit eviction/timeout options (NEW v3.0).
///
/// `conn_str`: NUL-terminated UTF-8 connection string.
/// `max_size`: maximum number of connections.
/// `options_json`: NUL-terminated UTF-8 JSON
///   `{ "idle_timeout_ms"?: int, "max_lifetime_ms"?: int, "connection_timeout_ms"?: int }`.
///   May be null/empty to use defaults.
///
/// Returns: pool_id (>0) on success, 0 on failure.
#[no_mangle]
pub extern "C" fn odbc_pool_create_with_options(
    conn_str: *const c_char,
    max_size: c_uint,
    options_json: *const c_char,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        if conn_str.is_null() {
            return 0;
        }
        // SAFETY: `conn_str` is non-null (checked above); caller guarantees a
        // valid NUL-terminated C string for the duration of this call.
        let Some(c_str) = (unsafe { guard::ptr_to_cstr(conn_str) }) else {
            return 0;
        };
        let conn_str_rust = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return 0,
        };

        let opts = if options_json.is_null() {
            crate::pool::PoolOptions::default()
        } else {
            // SAFETY: `options_json` is non-null (checked above); caller
            // guarantees it is a valid NUL-terminated C string.
            let opt_cstr = match unsafe { guard::ptr_to_cstr(options_json) } {
                Some(c) => c,
                None => return 0,
            };
            let s = match opt_cstr.to_str() {
                Ok(s) => s,
                Err(_) => return 0,
            };
            if s.trim().is_empty() {
                crate::pool::PoolOptions::default()
            } else {
                #[derive(serde::Deserialize)]
                struct OptsJson {
                    #[serde(default)]
                    idle_timeout_ms: Option<u64>,
                    #[serde(default)]
                    max_lifetime_ms: Option<u64>,
                    #[serde(default)]
                    connection_timeout_ms: Option<u64>,
                }
                let parsed: OptsJson = match serde_json::from_str(s) {
                    Ok(p) => p,
                    Err(_) => return 0,
                };
                crate::pool::PoolOptions {
                    idle_timeout: parsed.idle_timeout_ms.map(Duration::from_millis),
                    max_lifetime: parsed.max_lifetime_ms.map(Duration::from_millis),
                    connection_timeout: parsed.connection_timeout_ms.map(Duration::from_millis),
                }
            }
        };

        pool_create_inner(conn_str_rust, max_size, opts)
    })
}

/// Get connection from pool
/// pool_id: pool ID from odbc_pool_create
/// Returns: connection_id (>0) on success, 0 on failure
#[no_mangle]
pub extern "C" fn odbc_pool_get_connection(pool_id: c_uint) -> c_uint {
    crate::ffi_guard_id!(c_uint, { checkout_pooled_connection(pool_id) })
}

/// Release pooled connection back to pool.
/// RAII: rolls back any active transaction and restores autocommit before return.
/// Closes all prepared statements for this connection before release.
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_pool_release_connection(connection_id: c_uint) -> c_int {
    crate::ffi_guard_int!({ checkin_pooled_connection(connection_id) })
}

/// Health check for pool
/// pool_id: pool ID
/// Returns: 1 if healthy, 0 if unhealthy, -1 on error (invalid pool or internal failure)
#[no_mangle]
pub extern "C" fn odbc_pool_health_check(pool_id: c_uint) -> c_int {
    crate::ffi_guard_int!({ pool_health_check(pool_id) })
}

/// Get pool state (size and idle connections)
/// pool_id: pool ID
/// out_size: output for pool size
/// out_idle: output for idle connections
/// Returns: 0 on success, non-zero on error
#[no_mangle]
pub extern "C" fn odbc_pool_get_state(
    pool_id: c_uint,
    out_size: *mut c_uint,
    out_idle: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({ pool_get_state(pool_id, out_size, out_idle) })
}

/// Get pool state as JSON (detailed metrics for monitoring).
///
/// Writes UTF-8 JSON into `buffer`. Format:
/// ```json
/// {
///   "total_connections": 10,
///   "idle_connections": 8,
///   "active_connections": 2,
///   "max_size": 10,
///   "wait_count": 0,
///   "wait_time_ms": 0,
///   "max_wait_time_ms": 0,
///   "avg_wait_time_ms": 0
/// }
/// ```
///
/// `wait_*` fields are reserved for future instrumentation (r2d2 does not expose them).
/// Returns: 0 on success; -1 on error; -2 if buffer too small.
#[no_mangle]
pub extern "C" fn odbc_pool_get_state_json(
    pool_id: c_uint,
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({ pool_get_state_json(pool_id, buffer, buffer_len, out_written) })
}

/// Resize pool by recreating it with new max_size.
///
/// All connections must be released before resize. Returns -1 if pool has
/// checked-out connections or on error. r2d2 does not support in-place resize;
/// the pool is recreated with the same connection string.
#[no_mangle]
pub extern "C" fn odbc_pool_set_size(pool_id: c_uint, new_max_size: c_uint) -> c_int {
    crate::ffi_guard_int!({ pool_set_size(pool_id, new_max_size) })
}

/// Close and remove pool.
/// RAII: rolls back and restores autocommit on checked-out connections before close.
/// Releases all checked-out connections and closes their statements.
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_pool_close(pool_id: c_uint) -> c_int {
    crate::ffi_guard_int!({ close_pool(pool_id) })
}

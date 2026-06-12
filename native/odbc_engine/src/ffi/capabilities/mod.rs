// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

mod helpers;

use super::global::*;
use super::prelude::*;
use crate::ffi::guard;
use helpers::{
    detect_dbms_info_on_runnable, encode_prepared_cache_metrics, parse_columns_csv,
    parse_cstr_zero_out, parse_dml_verb, parse_session_options, parse_upsert_payload,
    require_dialect_sql_ptrs, require_output_buffer, require_sql_builder_ptrs, upsert_column_refs,
    upsert_update_refs, write_fixed_metrics_buffer, write_null_terminated_utf8, write_utf8_output,
    PREPARED_CACHE_METRICS_BYTES,
};

use std::os::raw::{c_char, c_int, c_uint};

// ============================================================================
// Metadata Cache Management
// ============================================================================

/// Enable or reconfigure the metadata cache.
///
/// # Parameters
/// - `max_size`: maximum number of entries per cache (schemas and payloads)
/// - `ttl_secs`: time-to-live in seconds for cached entries
///
/// # Returns
/// 0 on success, -1 on failure
#[no_mangle]
pub extern "C" fn odbc_metadata_cache_enable(max_size: c_uint, ttl_secs: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };

        let new_cache = crate::engine::core::metadata_cache::MetadataCache::new(
            max_size as usize,
            std::time::Duration::from_secs(ttl_secs as u64),
        );
        state.metadata_cache = new_cache;
        0
    })
}

/// Get metadata cache statistics as JSON.
///
/// Returns JSON with: `max_size`, `ttl_secs`, `schema_entries`, `payload_entries`
///
/// # Returns
/// 0 on success, -1 on error, -2 if buffer too small
#[no_mangle]
pub extern "C" fn odbc_metadata_cache_stats(
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if !require_output_buffer(buffer, buffer_len, out_written) {
            set_out_written_zero(out_written);
            return -1;
        }

        let Some(state) = try_lock_global_state() else {
            set_out_written_zero(out_written);
            return -1;
        };

        let stats = state.metadata_cache.stats();
        drop(state);

        let data = match serde_json::to_vec(&stats) {
            Ok(bytes) => bytes,
            Err(_) => {
                set_out_written_zero(out_written);
                return -1;
            }
        };

        write_utf8_output(&data, buffer, buffer_len, out_written)
    })
}

/// Clear all entries from the metadata cache.
///
/// # Returns
/// 0 on success, -1 on failure
#[no_mangle]
pub extern "C" fn odbc_metadata_cache_clear() -> c_int {
    crate::ffi_guard_int!({
        let Some(state) = try_lock_global_state() else {
            return -1;
        };

        state.metadata_cache.clear();
        0
    })
}

/// Get prepared statement cache metrics.
/// Writes 64 bytes to buffer:
/// cache_size(u64), cache_max_size(u64), cache_hits(u64), cache_misses(u64),
/// total_prepares(u64), total_executions(u64), memory_usage_bytes(u64),
/// avg_executions_per_stmt(f64 bits).
/// Returns 0 on success, -1 on error, -2 if buffer too small.
#[no_mangle]
pub extern "C" fn odbc_get_cache_metrics(
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if buffer.is_null() || out_written.is_null() {
            return -1;
        }
        if buffer_len < PREPARED_CACHE_METRICS_BYTES as c_uint {
            set_out_written_needed(out_written, PREPARED_CACHE_METRICS_BYTES);
            return -2;
        }
        let _state = match try_lock_global_state() {
            Some(state) => state,
            None => return -1,
        };

        let payload = match get_global_metrics().get_prepared_cache_metrics() {
            Some(metrics) => encode_prepared_cache_metrics(&metrics),
            None => [0u8; PREPARED_CACHE_METRICS_BYTES],
        };

        // SAFETY: `buffer` and `out_written` are non-null; `buffer_len >= 64`.
        unsafe {
            write_fixed_metrics_buffer(&payload, buffer, out_written);
        }
        0
    })
}

/// Clear prepared statement cache.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn odbc_clear_statement_cache() -> c_int {
    crate::ffi_guard_int!({
        let Some(_state) = try_lock_global_state() else {
            return -1;
        };

        get_global_metrics().clear_prepared_cache();
        0
    })
}

/// Detect database driver from connection string.
/// conn_str: null-terminated UTF-8 connection string
/// out_buf: output buffer for driver name (null-terminated UTF-8)
/// buffer_len: size of out_buf
/// Returns: 1 if driver detected and name written, 0 if unknown (writes "unknown")
#[no_mangle]
pub extern "C" fn odbc_detect_driver(
    conn_str: *const c_char,
    out_buf: *mut c_char,
    buffer_len: c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if conn_str.is_null() || out_buf.is_null() || buffer_len == 0 {
            return 0;
        }
        let conn_str_rust = match unsafe { guard::ptr_to_cstr(conn_str) } {
            Some(c) => match c.to_str() {
                Ok(s) => s,
                Err(_) => return 0,
            },
            None => return 0,
        };
        let registry = ffi_plugin_registry();
        let name = registry
            .detect_driver(conn_str_rust)
            .unwrap_or_else(|| "unknown".to_string());
        // SAFETY: `out_buf` is non-null with `buffer_len > 0` (checked above).
        unsafe {
            write_null_terminated_utf8(&name, out_buf, buffer_len);
        }
        if name == "unknown" {
            0
        } else {
            1
        }
    })
}

/// Get driver capabilities from connection string as JSON.
/// conn_str: null-terminated UTF-8 connection string
/// buffer: output buffer for JSON payload (UTF-8)
/// buffer_len: size of buffer
/// out_written: actual bytes written (excluding null terminator)
/// Returns: 0 on success, -1 on error, -2 if buffer too small
#[no_mangle]
pub extern "C" fn odbc_get_driver_capabilities(
    conn_str: *const c_char,
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if conn_str.is_null() || !require_output_buffer(buffer, buffer_len, out_written) {
            set_out_written_zero(out_written);
            return -1;
        }
        let conn_str_rust = match unsafe { parse_cstr_zero_out(conn_str, out_written) } {
            Some(value) => value,
            None => return -1,
        };
        let caps = DriverCapabilities::detect_from_connection_string(conn_str_rust);
        let json = match caps.to_json() {
            Ok(value) => value,
            Err(_) => {
                set_out_written_zero(out_written);
                return -1;
            }
        };
        write_utf8_output(json.as_bytes(), buffer, buffer_len, out_written)
    })
}

/// Live DBMS introspection via `SQLGetInfo` for an OPEN connection (NEW in v2.1).
///
/// Returns a JSON document:
/// ```json
/// {
///   "dbms_name": "Microsoft SQL Server",
///   "engine": "sqlserver",
///   "max_catalog_name_len": 128,
///   "max_schema_name_len": 128,
///   "max_table_name_len": 128,
///   "max_column_name_len": 128,
///   "current_catalog": "master",
///   "capabilities": { ... }
/// }
/// ```
///
/// Use this instead of `odbc_get_driver_capabilities` when you have already
/// established a connection and want the most accurate identification:
///
/// - DSN-only connection strings (no `Driver=` token) are correctly classified.
/// - MariaDB vs MySQL is distinguished.
/// - Custom / vendor-specific drivers (Devart, DataDirect, ...) work because
///   the *server* tells us who it is.
///
/// `conn_id`: connection ID from `odbc_connect*` or `odbc_pool_get_connection`.
/// `buffer`/`buffer_len`: pre-allocated UTF-8 output buffer.
/// `out_written`: actual bytes written (excluding any null terminator).
///
/// Returns: `0` on success, `-1` on error (invalid handle / SQLGetInfo failed),
/// `-2` if `buffer_len` is too small.
#[no_mangle]
pub extern "C" fn odbc_get_connection_dbms_info(
    conn_id: c_uint,
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if !require_output_buffer(buffer, buffer_len, out_written) {
            set_out_written_zero(out_written);
            return -1;
        }
        let Some(mut state) = try_lock_global_state() else {
            set_out_written_zero(out_written);
            return -1;
        };
        let target = match take_runnable_connection(&mut state, conn_id) {
            Ok(target) => target,
            Err(e) => {
                set_connection_structured_error(&mut state, conn_id, e.to_structured());
                set_out_written_zero(out_written);
                return -1;
            }
        };
        drop(state);

        let info_result = detect_dbms_info_on_runnable(&target);

        let Some(mut state) = try_lock_global_state() else {
            set_out_written_zero(out_written);
            return -1;
        };
        restore_pooled_connection(&mut state, conn_id, target);

        let info = match info_result {
            Ok(value) => value,
            Err(e) => {
                set_connection_error(&mut state, conn_id, e.to_string());
                set_out_written_zero(out_written);
                return -1;
            }
        };
        let json = match info.to_json() {
            Ok(value) => value,
            Err(_) => {
                set_out_written_zero(out_written);
                return -1;
            }
        };
        write_utf8_output(json.as_bytes(), buffer, buffer_len, out_written)
    })
}

/// Build a dialect-specific UPSERT SQL for the connection-string-resolved plugin (NEW v3.0).
///
/// `conn_str`: NUL-terminated UTF-8 connection string (only the driver token is used).
/// `table`: NUL-terminated UTF-8 table name (may be schema.table).
/// `payload_json`: NUL-terminated UTF-8 JSON `{ "columns": [...], "conflict": [...], "update": [...]? }`.
/// `out_buf`/`buf_len`/`out_written`: standard output buffer contract.
/// Returns: 0 on success, -1 invalid argument, -2 buffer too small, -3 unsupported plugin.
#[no_mangle]
pub extern "C" fn odbc_build_upsert_sql(
    conn_str: *const c_char,
    table: *const c_char,
    payload_json: *const c_char,
    out_buf: *mut u8,
    buf_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if !require_dialect_sql_ptrs(conn_str, table, payload_json, out_buf, buf_len, out_written) {
            set_out_written_zero(out_written);
            return -1;
        }
        let conn_str_rs = match unsafe { helpers::parse_cstr(conn_str) } {
            Some(value) => value,
            None => return -1,
        };
        let table_rs = match unsafe { helpers::parse_cstr(table) } {
            Some(value) => value,
            None => return -1,
        };
        let payload_rs = match unsafe { helpers::parse_cstr(payload_json) } {
            Some(value) => value,
            None => return -1,
        };

        let payload = match parse_upsert_payload(payload_rs) {
            Some(value) => value,
            None => return -1,
        };
        let (columns, conflict) = upsert_column_refs(&payload);
        let update_owned = upsert_update_refs(&payload);

        let registry = ffi_plugin_registry();
        let result = match registry.build_upsert_sql(
            conn_str_rs,
            table_rs,
            &columns,
            &conflict,
            update_owned.as_deref(),
        ) {
            Some(value) => value,
            None => return -3,
        };
        let sql = match result {
            Ok(value) => value,
            Err(_) => return -3,
        };
        write_utf8_output(sql.as_bytes(), out_buf, buf_len, out_written)
    })
}

/// Append a dialect-specific RETURNING/OUTPUT clause to a DML statement (NEW v3.0).
///
/// `conn_str`: NUL-terminated UTF-8 connection string.
/// `sql`: NUL-terminated UTF-8 INSERT/UPDATE/DELETE.
/// `verb`: 0=Insert, 1=Update, 2=Delete.
/// `columns_csv`: NUL-terminated UTF-8 comma-separated column names.
/// Returns: 0 success, -1 invalid argument, -2 buffer too small, -3 unsupported plugin.
#[no_mangle]
pub extern "C" fn odbc_append_returning_sql(
    conn_str: *const c_char,
    sql: *const c_char,
    verb: c_int,
    columns_csv: *const c_char,
    out_buf: *mut u8,
    buf_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if !require_dialect_sql_ptrs(conn_str, sql, columns_csv, out_buf, buf_len, out_written) {
            set_out_written_zero(out_written);
            return -1;
        }
        let conn_str_rs = match unsafe { helpers::parse_cstr(conn_str) } {
            Some(value) => value,
            None => return -1,
        };
        let sql_rs = match unsafe { helpers::parse_cstr(sql) } {
            Some(value) => value,
            None => return -1,
        };
        let cols_rs = match unsafe { helpers::parse_cstr(columns_csv) } {
            Some(value) => value,
            None => return -1,
        };
        let verb = match parse_dml_verb(verb) {
            Some(value) => value,
            None => return -1,
        };
        let cols = parse_columns_csv(cols_rs);

        let registry = ffi_plugin_registry();
        let result = match registry.append_returning_sql(conn_str_rs, sql_rs, verb, &cols) {
            Some(value) => value,
            None => return -3,
        };
        let out_sql = match result {
            Ok(value) => value,
            Err(_) => return -3,
        };
        write_utf8_output(out_sql.as_bytes(), out_buf, buf_len, out_written)
    })
}

/// Get the post-connect session-init SQL statements as a JSON array of strings (NEW v3.0).
///
/// `conn_str`: NUL-terminated UTF-8 connection string.
/// `options_json`: NUL-terminated UTF-8 JSON of `SessionOptions`
///   `{ "application_name"?: str, "timezone"?: str, "charset"?: str, "schema"?: str, "extra_sql"?: [str] }`
///   or empty/null for defaults.
#[no_mangle]
pub extern "C" fn odbc_get_session_init_sql(
    conn_str: *const c_char,
    options_json: *const c_char,
    out_buf: *mut u8,
    buf_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if !require_sql_builder_ptrs(conn_str, out_buf, buf_len, out_written) {
            set_out_written_zero(out_written);
            return -1;
        }
        let conn_str_rs = match unsafe { helpers::parse_cstr(conn_str) } {
            Some(value) => value,
            None => return -1,
        };
        let opts = match unsafe { parse_session_options(options_json) } {
            Some(value) => value,
            None => return -1,
        };

        let registry = ffi_plugin_registry();
        let stmts = registry
            .session_init_sql(conn_str_rs, &opts)
            .unwrap_or_default();
        let json = match serde_json::to_string(&stmts) {
            Ok(value) => value,
            Err(_) => return -1,
        };
        write_utf8_output(json.as_bytes(), out_buf, buf_len, out_written)
    })
}

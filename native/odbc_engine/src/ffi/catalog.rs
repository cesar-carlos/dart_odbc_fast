// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use super::global::*;
use super::prelude::*;
use crate::ffi::guard;
use crate::ffi::state;

use std::os::raw::{c_char, c_int, c_uint};

#[no_mangle]
pub extern "C" fn odbc_catalog_tables(
    conn_id: c_uint,
    catalog: *const c_char,
    schema: *const c_char,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if out_buffer.is_null() || out_written.is_null() {
            return -1;
        }

        let cat_opt = ptr_to_opt_str(catalog);
        let sch_opt = ptr_to_opt_str(schema);

        let cat_ref = cat_opt.as_deref();
        let sch_ref = sch_opt.as_deref();

        run_buffered_cached_call(conn_id, out_buffer, buffer_len, out_written, |cached| {
            list_tables_cached(cached, cat_ref, sch_ref)
        })
    })
}

/// Catalog: list columns for a table. Uses INFORMATION_SCHEMA.COLUMNS.
/// table: table name, or "schema.table".
/// Returns: 0 on success, -1 on error, -2 if buffer too small.
#[no_mangle]
pub extern "C" fn odbc_catalog_columns(
    conn_id: c_uint,
    table: *const c_char,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if table.is_null() || out_buffer.is_null() || out_written.is_null() {
            return -1;
        }

        // SAFETY: `table` is non-null (checked above); caller guarantees a valid
        // NUL-terminated UTF-8 C string for the duration of this call.
        let Some(c_str) = (unsafe { guard::ptr_to_cstr(table) }) else {
            return -1;
        };
        let table_str = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return -1,
        };

        let cache_key = build_catalog_cache_key(conn_id, table_str);
        {
            let Some(cache) = state::metadata_cache_read() else {
                return -1;
            };
            if let Some(cached_data) = cache.get_payload_shared(&cache_key) {
                drop(cache);
                let Some(mut state) = try_lock_global_state() else {
                    return -1;
                };
                if state::contains_connection(conn_id) || state::contains_pooled_connection(conn_id)
                {
                    return write_connection_output_buffer(
                        &mut state,
                        conn_id,
                        cached_data.as_ref(),
                        out_buffer,
                        buffer_len,
                        out_written,
                    );
                }
                drop(state);
                if let Some(cache) = state::metadata_cache_read() {
                    cache.remove_payload(&cache_key);
                }
            }
        }

        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };

        let metrics = state::ffi_metrics();
        let start = Instant::now();
        let target = match take_runnable_connection(&mut state, conn_id) {
            Ok(target) => target,
            Err(e) => {
                set_connection_structured_error(&mut state, conn_id, e.to_structured());
                set_out_written_zero(out_written);
                return -1;
            }
        };
        let mut target_guard = RunnableTargetGuard::new(conn_id, target);
        drop(state);

        let result = target_guard
            .target_mut()
            .with_cached(|cached| list_columns_cached(cached, table_str));

        let Some(mut state) = try_lock_global_state() else {
            set_out_written_zero(out_written);
            return -1;
        };
        restore_pooled_connection(&mut state, conn_id, target_guard.take_target());

        match result {
            Ok(data) => {
                let elapsed = start.elapsed();
                if let Some(cache) = state::metadata_cache_read() {
                    cache.cache_payload(&cache_key, &data);
                }
                let status = write_connection_output_buffer(
                    &mut state,
                    conn_id,
                    &data,
                    out_buffer,
                    buffer_len,
                    out_written,
                );
                if status == FFI_OK {
                    metrics.record_query(elapsed);
                } else {
                    metrics.record_error();
                }
                status
            }
            Err(e) => {
                metrics.record_error();
                set_connection_structured_error(&mut state, conn_id, e.to_structured());
                set_out_written_zero(out_written);
                -1
            }
        }
    })
}

/// Catalog: list distinct data types. Uses INFORMATION_SCHEMA.COLUMNS.
/// Returns: 0 on success, -1 on error, -2 if buffer too small.
#[no_mangle]
pub extern "C" fn odbc_catalog_type_info(
    conn_id: c_uint,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if out_buffer.is_null() || out_written.is_null() {
            return -1;
        }

        run_buffered_connection_call(conn_id, out_buffer, buffer_len, out_written, get_type_info)
    })
}

/// Catalog: list primary keys for a table. Uses INFORMATION_SCHEMA.
/// table: table name, or "schema.table".
/// Returns: 0 on success, -1 on error, -2 if buffer too small.
/// Result columns: TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, CONSTRAINT_NAME
#[no_mangle]
pub extern "C" fn odbc_catalog_primary_keys(
    conn_id: c_uint,
    table: *const c_char,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if table.is_null() || out_buffer.is_null() || out_written.is_null() {
            return -1;
        }

        // SAFETY: `table` is non-null (checked above); caller guarantees a valid
        // NUL-terminated UTF-8 C string for the duration of this call.
        let Some(c_str) = (unsafe { guard::ptr_to_cstr(table) }) else {
            return -1;
        };
        let table_str = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => {
                let Some(mut s) = try_lock_global_state() else {
                    return -1;
                };
                set_connection_error(&mut s, conn_id, "Invalid table name (UTF-8)".to_string());
                return -1;
            }
        };

        run_buffered_cached_call(conn_id, out_buffer, buffer_len, out_written, |cached| {
            list_primary_keys_cached(cached, table_str)
        })
    })
}

/// Catalog: list foreign keys for a table. Uses INFORMATION_SCHEMA.
/// table: table name, or "schema.table".
/// Returns: 0 on success, -1 on error, -2 if buffer too small.
/// Result columns: CONSTRAINT_NAME, FROM_TABLE, FROM_COLUMN, TO_TABLE, TO_COLUMN, UPDATE_RULE, DELETE_RULE
#[no_mangle]
pub extern "C" fn odbc_catalog_foreign_keys(
    conn_id: c_uint,
    table: *const c_char,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if table.is_null() || out_buffer.is_null() || out_written.is_null() {
            return -1;
        }

        // SAFETY: `table` is non-null (checked above); caller guarantees a valid
        // NUL-terminated UTF-8 C string for the duration of this call.
        let Some(c_str) = (unsafe { guard::ptr_to_cstr(table) }) else {
            return -1;
        };
        let table_str = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => {
                let Some(mut s) = try_lock_global_state() else {
                    return -1;
                };
                set_connection_error(&mut s, conn_id, "Invalid table name (UTF-8)".to_string());
                return -1;
            }
        };

        run_buffered_cached_call(conn_id, out_buffer, buffer_len, out_written, |cached| {
            list_foreign_keys_cached(cached, table_str)
        })
    })
}

/// Catalog: list indexes for a table. Uses INFORMATION_SCHEMA.
/// table: table name, or "schema.table".
/// Returns: 0 on success, -1 on error, -2 if buffer too small.
/// Result columns: INDEX_NAME, TABLE_NAME, COLUMN_NAME, IS_UNIQUE, IS_PRIMARY, ORDINAL_POSITION
#[no_mangle]
pub extern "C" fn odbc_catalog_indexes(
    conn_id: c_uint,
    table: *const c_char,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    crate::ffi_guard_int!({
        if table.is_null() || out_buffer.is_null() || out_written.is_null() {
            return -1;
        }

        // SAFETY: `table` is non-null (checked above); caller guarantees a valid
        // NUL-terminated UTF-8 C string for the duration of this call.
        let Some(c_str) = (unsafe { guard::ptr_to_cstr(table) }) else {
            return -1;
        };
        let table_str = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => {
                let Some(mut s) = try_lock_global_state() else {
                    return -1;
                };
                set_connection_error(&mut s, conn_id, "Invalid table name (UTF-8)".to_string());
                return -1;
            }
        };

        run_buffered_cached_call(conn_id, out_buffer, buffer_len, out_written, |cached| {
            list_indexes_cached(cached, table_str)
        })
    })
}

pub(crate) fn ptr_to_opt_str(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: `ptr` is non-null (checked above); caller guarantees a valid
    // NUL-terminated C string for the duration of this call.
    let c_str = unsafe { guard::ptr_to_cstr(ptr)? };
    let s = c_str.to_str().ok()?;
    let t = s.trim();
    if t.is_empty() {
        return None;
    }
    Some(t.to_string())
}

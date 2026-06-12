// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use super::global::*;
use crate::ffi::guard;
use crate::ffi::state;

use crate::engine::Transaction;
use std::os::raw::{c_char, c_int, c_uint};

pub(crate) fn validate_connection_string_format(s: &str) -> Option<String> {
    if s.is_empty() {
        return Some("Connection string is empty".to_string());
    }
    if s.contains('\0') {
        return Some("Connection string contains null byte".to_string());
    }
    let mut brace_depth = 0u32;
    for ch in s.chars() {
        match ch {
            '{' => brace_depth = brace_depth.saturating_add(1),
            '}' if brace_depth == 0 => {
                return Some("Unbalanced braces in connection string".to_string());
            }
            '}' => brace_depth -= 1,
            _ => {}
        }
    }
    if brace_depth != 0 {
        return Some("Unbalanced braces in connection string".to_string());
    }
    let parts: Vec<&str> = s
        .split(';')
        .map(|p| p.trim())
        .filter(|p| !p.is_empty())
        .collect();
    if parts.is_empty() {
        return Some("No key=value pairs found".to_string());
    }
    let mut has_valid_pair = false;
    for part in &parts {
        if let Some((key, _)) = part.split_once('=') {
            if !key.trim().is_empty() {
                has_valid_pair = true;
                break;
            }
        }
    }
    if !has_valid_pair {
        return Some("No valid key=value pairs (need DSN= or Driver= etc.)".to_string());
    }
    None
}

/// Connect to database
/// conn_str: null-terminated UTF-8 connection string
/// Returns: connection ID (>0) on success, 0 on failure
#[no_mangle]
pub extern "C" fn odbc_connect(conn_str: *const c_char) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        if conn_str.is_null() {
            return 0;
        }

        let Some(c_str) = (unsafe { guard::ptr_to_cstr(conn_str) }) else {
            return 0;
        };
        let conn_str_rust = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return 0,
        };

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };

        let env = match &state.env {
            Some(e) => e.clone(),
            None => {
                set_error(&mut state, "Environment not initialized".to_string());
                return 0;
            }
        };

        let handles = {
            let Some(env_guard) = env.lock().ok() else {
                set_error(&mut state, "Failed to lock environment mutex".to_string());
                return 0;
            };
            env_guard.get_handles()
        };
        drop(state);

        let result = crate::engine::OdbcConnection::connect(handles, conn_str_rust);

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };
        match result {
            Ok(conn) => {
                let conn_id = conn.get_connection_id();
                state.connections.insert(conn_id, conn);
                #[cfg(feature = "sqlserver-bcp")]
                state
                    .connection_strings
                    .insert(conn_id, conn_str_rust.to_string());
                state::ffi_audit_logger().log_connection(conn_id, conn_str_rust);
                conn_id
            }
            Err(e) => {
                // Connection failed before conn_id is available, use global error
                set_error(&mut state, format!("odbc_connect failed: {}", e));
                0
            }
        }
    })
}

/// Connect to database with login timeout.
/// conn_str: null-terminated UTF-8 connection string
/// timeout_ms: login timeout in milliseconds (0 = use default)
/// Returns: connection ID (>0) on success, 0 on failure
#[no_mangle]
pub extern "C" fn odbc_connect_with_timeout(conn_str: *const c_char, timeout_ms: c_uint) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        if conn_str.is_null() {
            return 0;
        }

        let Some(c_str) = (unsafe { guard::ptr_to_cstr(conn_str) }) else {
            return 0;
        };
        let conn_str_rust = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return 0,
        };

        // timeout_ms == 0 means "no timeout" (use driver default). Values below
        // 1000 ms are rounded up to 1 second because the ODBC API accepts only
        // whole seconds for the login timeout.
        let timeout_secs = match timeout_ms {
            0 => None,
            ms => Some((ms / 1000).max(1)),
        };

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };

        let env = match &state.env {
            Some(e) => e.clone(),
            None => {
                set_error(&mut state, "Environment not initialized".to_string());
                return 0;
            }
        };

        let handles = {
            let Some(env_guard) = env.lock().ok() else {
                set_error(&mut state, "Failed to lock environment mutex".to_string());
                return 0;
            };
            env_guard.get_handles()
        };
        drop(state);

        let result = match timeout_secs {
            None => crate::engine::OdbcConnection::connect(handles, conn_str_rust),
            Some(secs) => {
                crate::engine::OdbcConnection::connect_with_timeout(handles, conn_str_rust, secs)
            }
        };

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };
        match result {
            Ok(conn) => {
                let conn_id = conn.get_connection_id();
                state.connections.insert(conn_id, conn);
                #[cfg(feature = "sqlserver-bcp")]
                state
                    .connection_strings
                    .insert(conn_id, conn_str_rust.to_string());
                state::ffi_audit_logger().log_connection(conn_id, conn_str_rust);
                conn_id
            }
            Err(e) => {
                set_error(
                    &mut state,
                    format!("odbc_connect_with_timeout failed: {}", e),
                );
                0
            }
        }
    })
}

/// Disconnect from database
/// conn_id: connection ID returned by odbc_connect
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_disconnect(conn_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };

        #[cfg(feature = "sqlserver-bcp")]
        let _ = state.connection_strings.remove(&conn_id);

        if state.transaction_begins_in_progress.contains(&conn_id) {
            set_connection_error(
                &mut state,
                conn_id,
                "Cannot disconnect while transaction begin is in progress".to_string(),
            );
            return 1;
        }

        if let Some(conn) = state.connections.remove(&conn_id) {
            let transactions: Vec<Transaction> =
                take_transactions_for_connection(&mut state, conn_id)
                    .into_iter()
                    .map(|(_, txn)| txn)
                    .collect();
            let stmts_to_drop: Vec<u32> = state
                .statements
                .iter()
                .filter(|(_, s)| s.conn_id() == conn_id)
                .map(|(id, _)| *id)
                .collect();
            for stmt_id in &stmts_to_drop {
                state.statements.remove(stmt_id);
            }
            let streams_to_drop: Vec<u32> = state
                .stream_connections
                .iter()
                .filter_map(|(stream_id, stream_conn_id)| {
                    (*stream_conn_id == conn_id).then_some(*stream_id)
                })
                .collect();
            for stream_id in streams_to_drop {
                if let Some(stream) = state.streams.remove(&stream_id) {
                    stream.cancel();
                }
                state.stream_connections.remove(&stream_id);
            }
            drop(state);
            if let Some(mut async_mgr) = lock_async_requests() {
                async_mgr.free_for_connection(conn_id);
            }

            for txn in transactions {
                let _ = txn.rollback();
            }
            let disconnect_result = conn.disconnect();

            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };
            match disconnect_result {
                Ok(_) => {
                    state::clear_connection_error(conn_id);
                    0
                }
                Err(e) => {
                    set_connection_error(
                        &mut state,
                        conn_id,
                        format!("odbc_disconnect failed: {}", e),
                    );
                    1
                }
            }
        } else {
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            1
        }
    })
}

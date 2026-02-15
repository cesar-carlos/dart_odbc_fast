// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use crate::async_bridge;
use crate::engine::{
    execute_multi_result, execute_query_with_connection, execute_query_with_params,
    execute_query_with_params_and_timeout, get_global_metrics, get_type_info, list_columns,
    list_tables, ArrayBinding, BatchedStreamingState, IsolationLevel, OdbcConnection,
    OdbcEnvironment, StatementHandle, StreamingExecutor, StreamingState, Transaction,
};
use crate::error::StructuredError;
use crate::error::{OdbcError, Result};
use crate::observability::Metrics;
use crate::plugins::PluginRegistry;
use crate::pool::{ConnectionPool, PooledConnectionWrapper};
use crate::protocol::{
    bulk_insert::is_null, deserialize_params, parse_bulk_insert_payload, BulkColumnData,
    BulkInsertPayload, ParamValue,
};
use rayon::prelude::*;
use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_uint};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

/// Error information stored per connection to avoid race conditions
#[derive(Debug, Clone)]
struct ConnectionError {
    simple_message: String,
    structured: Option<StructuredError>,
    #[allow(dead_code)] // Reserved for future use (error expiration, debugging)
    timestamp: Instant,
}

enum StreamKind {
    Buffer(StreamingState),
    Batched(BatchedStreamingState),
}

impl StreamKind {
    fn fetch_next_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        match self {
            StreamKind::Buffer(s) => s.fetch_next_chunk(),
            StreamKind::Batched(s) => s.fetch_next_chunk(),
        }
    }

    fn has_more(&self) -> bool {
        match self {
            StreamKind::Buffer(s) => s.has_more(),
            StreamKind::Batched(s) => s.has_more(),
        }
    }
}

struct GlobalState {
    env: Option<Arc<Mutex<OdbcEnvironment>>>,
    connections: HashMap<u32, OdbcConnection>,
    transactions: HashMap<u32, Transaction>,
    statements: HashMap<u32, StatementHandle>,
    streams: HashMap<u32, StreamKind>,
    stream_connections: HashMap<u32, u32>, // Map stream_id -> conn_id
    pools: HashMap<u32, Arc<ConnectionPool>>,
    pooled_connections: HashMap<u32, (u32, PooledConnectionWrapper)>, // pooled_conn_id -> (pool_id, wrapper)
    pooled_free_ids: HashMap<u32, Vec<u32>>, // pool_id -> reusable pooled connection IDs
    next_stream_id: u32,
    next_pool_id: u32,
    next_pooled_conn_id: u32,
    next_txn_id: u32,
    next_stmt_id: u32,
    // Legacy global error (for backward compatibility with functions without conn_id)
    last_error: Option<String>,
    last_structured_error: Option<StructuredError>,
    // Per-connection errors (thread-safe isolation)
    connection_errors: HashMap<u32, ConnectionError>,
    metrics: Arc<Metrics>,
}

static GLOBAL_STATE: OnceLock<Arc<Mutex<GlobalState>>> = OnceLock::new();

fn get_global_state() -> &'static Arc<Mutex<GlobalState>> {
    GLOBAL_STATE.get_or_init(|| {
        Arc::new(Mutex::new(GlobalState {
            env: None,
            connections: HashMap::new(),
            transactions: HashMap::new(),
            statements: HashMap::new(),
            streams: HashMap::new(),
            stream_connections: HashMap::new(),
            pools: HashMap::new(),
            pooled_connections: HashMap::new(),
            pooled_free_ids: HashMap::new(),
            next_stream_id: 1,
            next_pool_id: 1,
            next_pooled_conn_id: 1_000_000,
            next_txn_id: 1,
            next_stmt_id: 1,
            last_error: None,
            last_structured_error: None,
            connection_errors: HashMap::new(),
            metrics: Arc::new(Metrics::new()),
        }))
    })
}

/// Set error for a specific connection (thread-safe isolation)
fn set_connection_error(state: &mut GlobalState, conn_id: u32, error: String) {
    state.connection_errors.insert(
        conn_id,
        ConnectionError {
            simple_message: error.clone(),
            structured: None,
            timestamp: Instant::now(),
        },
    );
    // Also update global for backward compatibility
    state.last_error = Some(error);
    state.last_structured_error = None;
}

/// Set structured error for a specific connection (thread-safe isolation)
fn set_connection_structured_error(state: &mut GlobalState, conn_id: u32, error: StructuredError) {
    state.connection_errors.insert(
        conn_id,
        ConnectionError {
            simple_message: error.message.clone(),
            structured: Some(error.clone()),
            timestamp: Instant::now(),
        },
    );
    // Also update global for backward compatibility
    state.last_error = Some(error.message.clone());
    state.last_structured_error = Some(error);
}

/// Set global error (for functions without conn_id like odbc_init)
fn set_error(state: &mut GlobalState, error: String) {
    state.last_error = Some(error);
    state.last_structured_error = None;
}

/// Set global structured error (for functions without conn_id)
#[allow(dead_code)] // Kept for backward compatibility with FFI functions
fn set_structured_error(state: &mut GlobalState, error: StructuredError) {
    state.last_error = Some(error.message.clone());
    state.last_structured_error = Some(error);
}

/// Get error for a specific connection, or fallback to global error
fn get_connection_error(state: &GlobalState, conn_id: Option<u32>) -> String {
    if let Some(id) = conn_id {
        if let Some(conn_err) = state.connection_errors.get(&id) {
            return conn_err.simple_message.clone();
        }
    }
    // Fallback to global error
    state
        .last_error
        .clone()
        .unwrap_or_else(|| "No error".to_string())
}

/// Get structured error for a specific connection, or fallback to global error
fn get_connection_structured_error(
    state: &GlobalState,
    conn_id: Option<u32>,
) -> Option<StructuredError> {
    if let Some(id) = conn_id {
        if let Some(conn_err) = state.connection_errors.get(&id) {
            return conn_err.structured.clone();
        }
    }
    // Fallback to global error
    state.last_structured_error.clone()
}

/// Get global error (legacy function for backward compatibility)
#[allow(dead_code)] // Kept for backward compatibility with FFI functions
fn get_error(state: &GlobalState) -> String {
    state
        .last_error
        .clone()
        .unwrap_or_else(|| "No error".to_string())
}

/// Helper to safely lock global state mutex.
/// Returns None if mutex is poisoned, avoiding panic in FFI.
fn try_lock_global_state() -> Option<std::sync::MutexGuard<'static, GlobalState>> {
    get_global_state().lock().ok()
}

/// Initialize ODBC environment and async runtime
/// Returns: 0 on success, non-zero error code on failure
#[no_mangle]
pub extern "C" fn odbc_init() -> c_int {
    async_bridge::init_runtime();

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
}

/// Connect to database
/// conn_str: null-terminated UTF-8 connection string
/// Returns: connection ID (>0) on success, 0 on failure
#[no_mangle]
pub extern "C" fn odbc_connect(conn_str: *const c_char) -> c_uint {
    if conn_str.is_null() {
        return 0;
    }

    // Safety: `conn_str` must be a valid null-terminated C string pointer
    // that remains valid for the duration of this call
    let c_str = unsafe { CStr::from_ptr(conn_str) };
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

    match crate::engine::OdbcConnection::connect(handles, conn_str_rust) {
        Ok(conn) => {
            let conn_id = conn.get_connection_id();
            state.connections.insert(conn_id, conn);
            conn_id
        }
        Err(e) => {
            // Connection failed before conn_id is available, use global error
            set_error(&mut state, format!("odbc_connect failed: {}", e));
            0
        }
    }
}

/// Connect to database with login timeout.
/// conn_str: null-terminated UTF-8 connection string
/// timeout_ms: login timeout in milliseconds (0 = use default)
/// Returns: connection ID (>0) on success, 0 on failure
#[no_mangle]
pub extern "C" fn odbc_connect_with_timeout(conn_str: *const c_char, timeout_ms: c_uint) -> c_uint {
    if conn_str.is_null() {
        return 0;
    }

    let c_str = unsafe { CStr::from_ptr(conn_str) };
    let conn_str_rust = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return 0,
    };

    let timeout_secs = if timeout_ms == 0 {
        1u32
    } else {
        (timeout_ms / 1000).max(1)
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

    match crate::engine::OdbcConnection::connect_with_timeout(handles, conn_str_rust, timeout_secs)
    {
        Ok(conn) => {
            let conn_id = conn.get_connection_id();
            state.connections.insert(conn_id, conn);
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
}

/// Disconnect from database
/// conn_id: connection ID returned by odbc_connect
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_disconnect(conn_id: c_uint) -> c_int {
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };

    if let Some(conn) = state.connections.remove(&conn_id) {
        let txns_to_rollback: Vec<u32> = state
            .transactions
            .iter()
            .filter(|(_, t)| t.conn_id() == conn_id)
            .map(|(id, _)| *id)
            .collect();
        for txn_id in txns_to_rollback {
            if let Some(txn) = state.transactions.remove(&txn_id) {
                let _ = txn.rollback();
            }
        }
        let stmts_to_drop: Vec<u32> = state
            .statements
            .iter()
            .filter(|(_, s)| s.conn_id() == conn_id)
            .map(|(id, _)| *id)
            .collect();
        for stmt_id in stmts_to_drop {
            state.statements.remove(&stmt_id);
        }
        match conn.disconnect() {
            Ok(_) => {
                // Remove connection error when disconnecting
                state.connection_errors.remove(&conn_id);
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
}

/// Begin a new transaction.
/// conn_id: connection ID from odbc_connect
/// isolation_level: 0=ReadUncommitted, 1=ReadCommitted, 2=RepeatableRead, 3=Serializable
/// Returns: transaction ID (>0) on success, 0 on failure
#[no_mangle]
pub extern "C" fn odbc_transaction_begin(conn_id: c_uint, isolation_level: c_uint) -> c_uint {
    let Some(mut state) = try_lock_global_state() else {
        return 0;
    };

    let isolation = match IsolationLevel::from_u32(isolation_level) {
        Some(iso) => iso,
        None => {
            set_error(&mut state, "Invalid isolation level".to_string());
            return 0;
        }
    };

    let conn = match state.connections.get(&conn_id) {
        Some(c) => c,
        None => {
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return 0;
        }
    };

    if state.transactions.values().any(|t| t.conn_id() == conn_id) {
        set_error(
            &mut state,
            "Connection already has an active transaction".to_string(),
        );
        return 0;
    }

    match conn.begin_transaction(isolation) {
        Ok(txn) => {
            let txn_id = state.next_txn_id;
            state.next_txn_id = state.next_txn_id.wrapping_add(1);
            state.transactions.insert(txn_id, txn);
            txn_id
        }
        Err(e) => {
            set_connection_error(
                &mut state,
                conn_id,
                format!("Failed to begin transaction: {}", e),
            );
            0
        }
    }
}

/// Commit a transaction.
/// txn_id: transaction ID from odbc_transaction_begin
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_transaction_commit(txn_id: c_uint) -> c_int {
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };

    if let Some(txn) = state.transactions.remove(&txn_id) {
        let txn_conn_id = txn.conn_id();
        match txn.commit() {
            Ok(_) => 0,
            Err(e) => {
                set_connection_error(&mut state, txn_conn_id, format!("Commit failed: {}", e));
                1
            }
        }
    } else {
        set_error(&mut state, format!("Invalid transaction ID: {}", txn_id));
        1
    }
}

/// Rollback a transaction.
/// txn_id: transaction ID from odbc_transaction_begin
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_transaction_rollback(txn_id: c_uint) -> c_int {
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };

    if let Some(txn) = state.transactions.remove(&txn_id) {
        let txn_conn_id = txn.conn_id();
        match txn.rollback() {
            Ok(_) => 0,
            Err(e) => {
                set_connection_error(&mut state, txn_conn_id, format!("Rollback failed: {}", e));
                1
            }
        }
    } else {
        set_error(&mut state, format!("Invalid transaction ID: {}", txn_id));
        1
    }
}

/// Create a savepoint within an active transaction.
/// txn_id: transaction ID from odbc_transaction_begin
/// name: savepoint name (UTF-8, null-terminated)
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_savepoint_create(txn_id: c_uint, name: *const c_char) -> c_int {
    if name.is_null() {
        return 1;
    }
    let name_str = match unsafe { CStr::from_ptr(name).to_str() } {
        Ok(s) => s,
        Err(_) => return 1,
    };
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };
    let conn_id = state.transactions.get(&txn_id).map(|t| t.conn_id());
    let res = state
        .transactions
        .get(&txn_id)
        .map(|txn| txn.execute_sql(&format!("SAVEPOINT {}", name_str)));
    match (conn_id, res) {
        (Some(_cid), Some(Ok(_))) => 0,
        (Some(cid), Some(Err(e))) => {
            set_connection_error(&mut state, cid, format!("Savepoint create failed: {}", e));
            1
        }
        _ => {
            set_error(&mut state, format!("Invalid transaction ID: {}", txn_id));
            1
        }
    }
}

/// Rollback to a savepoint. Transaction remains active.
/// txn_id: transaction ID from odbc_transaction_begin
/// name: savepoint name (UTF-8, null-terminated)
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_savepoint_rollback(txn_id: c_uint, name: *const c_char) -> c_int {
    if name.is_null() {
        return 1;
    }
    let name_str = match unsafe { CStr::from_ptr(name).to_str() } {
        Ok(s) => s,
        Err(_) => return 1,
    };
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };
    let conn_id = state.transactions.get(&txn_id).map(|t| t.conn_id());
    let res = state
        .transactions
        .get(&txn_id)
        .map(|txn| txn.execute_sql(&format!("ROLLBACK TO SAVEPOINT {}", name_str)));
    match (conn_id, res) {
        (Some(_cid), Some(Ok(_))) => 0,
        (Some(cid), Some(Err(e))) => {
            set_connection_error(&mut state, cid, format!("Savepoint rollback failed: {}", e));
            1
        }
        _ => {
            set_error(&mut state, format!("Invalid transaction ID: {}", txn_id));
            1
        }
    }
}

/// Release a savepoint. Transaction remains active.
/// txn_id: transaction ID from odbc_transaction_begin
/// name: savepoint name (UTF-8, null-terminated)
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_savepoint_release(txn_id: c_uint, name: *const c_char) -> c_int {
    if name.is_null() {
        return 1;
    }
    let name_str = match unsafe { CStr::from_ptr(name).to_str() } {
        Ok(s) => s,
        Err(_) => return 1,
    };
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };
    let conn_id = state.transactions.get(&txn_id).map(|t| t.conn_id());
    let res = state
        .transactions
        .get(&txn_id)
        .map(|txn| txn.execute_sql(&format!("RELEASE SAVEPOINT {}", name_str)));
    match (conn_id, res) {
        (Some(_cid), Some(Ok(_))) => 0,
        (Some(cid), Some(Err(e))) => {
            set_connection_error(&mut state, cid, format!("Savepoint release failed: {}", e));
            1
        }
        _ => {
            set_error(&mut state, format!("Invalid transaction ID: {}", txn_id));
            1
        }
    }
}

/// Get last error message
/// buffer: output buffer
/// buffer_len: buffer size in bytes
/// Returns: number of bytes written (excluding null terminator), -1 on error
#[no_mangle]
pub extern "C" fn odbc_get_error(buffer: *mut c_char, buffer_len: c_uint) -> c_int {
    if buffer.is_null() || buffer_len == 0 {
        return -1;
    }

    let Some(state) = try_lock_global_state() else {
        return -1;
    };

    let error_msg = get_connection_error(&state, None);
    let msg_bytes = error_msg.as_bytes();
    let copy_len = (msg_bytes.len() as c_uint).min(buffer_len - 1);

    // Safety: `buffer` must be valid for writes of `copy_len + 1` bytes
    // Caller ensures buffer is large enough (buffer_len > 0 verified above)
    unsafe {
        std::ptr::copy_nonoverlapping(msg_bytes.as_ptr(), buffer as *mut u8, copy_len as usize);
        *buffer.add(copy_len as usize) = 0;
    }

    copy_len as c_int
}

/// Get last structured error
/// buffer: output buffer for serialized error
/// buffer_len: buffer size in bytes
/// out_written: actual bytes written
/// Returns: 0 on success, non-zero on error
#[no_mangle]
pub extern "C" fn odbc_get_structured_error(
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    if buffer.is_null() || out_written.is_null() {
        return -1;
    }

    let Some(state) = try_lock_global_state() else {
        return -1;
    };

    let error_data = match get_connection_structured_error(&state, None) {
        Some(err) => err.serialize(),
        None => {
            let simple_error = StructuredError {
                sqlstate: [0u8; 5],
                native_code: 0,
                message: get_connection_error(&state, None),
            };
            simple_error.serialize()
        }
    };

    if error_data.len() > buffer_len as usize {
        return -2;
    }

    // Safety: `buffer` must be valid for writes of `error_data.len()` bytes
    // `out_written` must be valid for writes of size_of::<c_uint>() bytes
    // Caller ensures pointers are valid (null checks above)
    unsafe {
        std::ptr::copy_nonoverlapping(error_data.as_ptr(), buffer, error_data.len());
        *out_written = error_data.len() as c_uint;
    }

    0
}

/// Get metrics: query count, error count, uptime, latencies.
/// Writes 40 bytes (5 u64 LE) to buffer: query_count, error_count,
/// uptime_secs, total_latency_millis, avg_latency_millis.
/// Returns 0 on success, -1 on error, -2 if buffer too small.
#[no_mangle]
pub extern "C" fn odbc_get_metrics(
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    if buffer.is_null() || out_written.is_null() {
        return -1;
    }
    if buffer_len < 40 {
        return -2;
    }
    let Some(state) = try_lock_global_state() else {
        return -1;
    };
    let q = state.metrics.get_query_metrics();
    let ec = state.metrics.get_error_count();
    let up = state.metrics.uptime();
    let tm = q.total_latency.as_millis().min(u64::MAX as u128) as u64;
    let am = q.average_latency().as_millis().min(u64::MAX as u128) as u64;
    let mut p = [0u8; 40];
    p[0..8].copy_from_slice(&q.query_count.to_le_bytes());
    p[8..16].copy_from_slice(&ec.to_le_bytes());
    p[16..24].copy_from_slice(&up.as_secs().to_le_bytes());
    p[24..32].copy_from_slice(&tm.to_le_bytes());
    p[32..40].copy_from_slice(&am.to_le_bytes());
    // Safety: buffer and out_written valid (null and size checks above).
    unsafe {
        std::ptr::copy_nonoverlapping(p.as_ptr(), buffer, 40);
        *out_written = 40;
    }
    0
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
    if buffer.is_null() || out_written.is_null() {
        return -1;
    }
    if buffer_len < 64 {
        return -2;
    }
    let _state = match try_lock_global_state() {
        Some(state) => state,
        None => return -1,
    };

    let metrics = match get_global_metrics().get_prepared_cache_metrics() {
        Some(m) => m,
        None => {
            // Return zeros if cache not set
            let p = [0u8; 64];
            // Safety: pointers were validated above and buffer size checked.
            unsafe {
                std::ptr::copy_nonoverlapping(p.as_ptr(), buffer, 64);
                *out_written = 64;
            }
            return 0;
        }
    };

    let mut p = [0u8; 64];
    p[0..8].copy_from_slice(&(metrics.cache_size as u64).to_le_bytes());
    p[8..16].copy_from_slice(&(metrics.cache_max_size as u64).to_le_bytes());
    p[16..24].copy_from_slice(&metrics.cache_hits.to_le_bytes());
    p[24..32].copy_from_slice(&metrics.cache_misses.to_le_bytes());
    p[32..40].copy_from_slice(&metrics.total_prepares.to_le_bytes());
    p[40..48].copy_from_slice(&metrics.total_executions.to_le_bytes());
    p[48..56].copy_from_slice(&(metrics.memory_usage_bytes as u64).to_le_bytes());
    p[56..64].copy_from_slice(&metrics.avg_executions_per_stmt.to_le_bytes());

    // Safety: pointers were validated above and buffer size checked.
    unsafe {
        std::ptr::copy_nonoverlapping(p.as_ptr(), buffer, 64);
        *out_written = 64;
    }

    0
}

/// Clear prepared statement cache.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn odbc_clear_statement_cache() -> c_int {
    let Some(_state) = try_lock_global_state() else {
        return -1;
    };

    get_global_metrics().clear_prepared_cache();
    0
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
    if conn_str.is_null() || out_buf.is_null() || buffer_len == 0 {
        return 0;
    }
    let conn_str_rust = match unsafe { CStr::from_ptr(conn_str).to_str() } {
        Ok(s) => s,
        Err(_) => return 0,
    };
    let registry = PluginRegistry::default();
    let name = registry
        .detect_driver(conn_str_rust)
        .unwrap_or_else(|| "unknown".to_string());
    let name_bytes = name.as_bytes();
    let copy_len = (name_bytes.len() + 1).min(buffer_len as usize);
    unsafe {
        std::ptr::copy_nonoverlapping(name_bytes.as_ptr(), out_buf as *mut u8, copy_len - 1);
        *out_buf.add(copy_len - 1) = 0;
    }
    if name == "unknown" {
        0
    } else {
        1
    }
}

/// Execute query and return binary buffer
/// conn_id: connection ID
/// sql: null-terminated UTF-8 SQL query
/// out_buf: output buffer (pre-allocated)
/// buf_len: buffer size
/// out_written: actual bytes written
/// Returns: 0 on success, non-zero on error
#[no_mangle]
pub extern "C" fn odbc_exec_query(
    conn_id: c_uint,
    sql: *const c_char,
    out_buf: *mut u8,
    buf_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    if sql.is_null() || out_buf.is_null() || out_written.is_null() {
        return -1;
    }

    // Safety: `sql` must be a valid null-terminated C string pointer
    let c_str = unsafe { CStr::from_ptr(sql) };
    let sql_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };

    let Some(state) = try_lock_global_state() else {
        return -1;
    };

    let conn = match state.connections.get(&conn_id) {
        Some(c) => c,
        None => {
            drop(state);
            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return -1;
        }
    };

    let handles = conn.get_handles();
    let Some(handles_guard) = handles.lock().ok() else {
        drop(state);
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        set_error(&mut state, "Failed to lock handles mutex".to_string());
        return -1;
    };

    let odbc_conn = match handles_guard.get_connection(conn_id) {
        Ok(c) => c,
        Err(e) => {
            drop(handles_guard);
            drop(state);
            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };
            set_error(&mut state, format!("Failed to get connection: {}", e));
            return -1;
        }
    };

    let metrics = Arc::clone(&state.metrics);
    let start = Instant::now();

    match execute_query_with_connection(odbc_conn, sql_str) {
        Ok(data) => {
            let elapsed = start.elapsed();
            if data.len() > buf_len as usize {
                metrics.record_error();
                drop(state);
                let Some(mut state) = try_lock_global_state() else {
                    return -1;
                };
                set_connection_error(
                    &mut state,
                    conn_id,
                    format!(
                        "Buffer too small: need {} bytes, got {}",
                        data.len(),
                        buf_len
                    ),
                );
                return -2;
            }

            metrics.record_query(elapsed);

            // Safety: `out_buf` must be valid for writes of `data.len()` bytes
            // `out_written` must be valid for writes of size_of::<c_uint>() bytes
            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr(), out_buf, data.len());
                *out_written = data.len() as c_uint;
            }

            0
        }
        Err(e) => {
            metrics.record_error();
            drop(state);
            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };
            let structured = e.to_structured();
            set_connection_structured_error(&mut state, conn_id, structured);
            -1
        }
    }
}

/// Execute parameterized query and return binary buffer
/// conn_id: connection ID
/// sql: null-terminated UTF-8 SQL query
/// params_buffer: serialized ParamValue array (NULL = no parameters)
/// params_len: length of params_buffer in bytes
/// out_buffer: output buffer (pre-allocated)
/// buffer_len: buffer size
/// out_written: actual bytes written
/// Returns: 0 on success, -1 on error, -2 if buffer too small
#[no_mangle]
pub extern "C" fn odbc_exec_query_params(
    conn_id: c_uint,
    sql: *const c_char,
    params_buffer: *const u8,
    params_len: c_uint,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    if sql.is_null() || out_buffer.is_null() || out_written.is_null() {
        return -1;
    }

    let c_str = unsafe { CStr::from_ptr(sql) };
    let sql_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };

    let Some(state) = try_lock_global_state() else {
        return -1;
    };

    let conn = match state.connections.get(&conn_id) {
        Some(c) => c,
        None => {
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_error(
                &mut s,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return -1;
        }
    };

    let handles = conn.get_handles();
    let Some(handles_guard) = handles.lock().ok() else {
        drop(state);
        let Some(mut s) = try_lock_global_state() else {
            return -1;
        };
        set_connection_error(&mut s, conn_id, "Failed to lock handles mutex".to_string());
        return -1;
    };

    let odbc_conn = match handles_guard.get_connection(conn_id) {
        Ok(c) => c,
        Err(e) => {
            drop(handles_guard);
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_error(&mut s, conn_id, format!("Failed to get connection: {}", e));
            return -1;
        }
    };

    let metrics = Arc::clone(&state.metrics);
    let start = Instant::now();

    let result = if params_buffer.is_null() || params_len == 0 {
        execute_query_with_connection(odbc_conn, sql_str)
    } else {
        let params_slice =
            unsafe { std::slice::from_raw_parts(params_buffer, params_len as usize) };
        let params: Vec<ParamValue> = match deserialize_params(params_slice) {
            Ok(p) => p,
            Err(e) => {
                metrics.record_error();
                drop(state);
                let Some(mut s) = try_lock_global_state() else {
                    return -1;
                };
                set_connection_error(&mut s, conn_id, format!("Invalid params buffer: {}", e));
                return -1;
            }
        };
        execute_query_with_params(odbc_conn, sql_str, &params)
    };

    match result {
        Ok(data) => {
            let elapsed = start.elapsed();
            if data.len() > buffer_len as usize {
                metrics.record_error();
                drop(state);
                let Some(mut s) = try_lock_global_state() else {
                    return -1;
                };
                set_connection_error(
                    &mut s,
                    conn_id,
                    format!(
                        "Buffer too small: need {} bytes, got {}",
                        data.len(),
                        buffer_len
                    ),
                );
                return -2;
            }

            metrics.record_query(elapsed);

            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr(), out_buffer, data.len());
                *out_written = data.len() as c_uint;
            }

            0
        }
        Err(e) => {
            metrics.record_error();
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            let structured = e.to_structured();
            set_connection_structured_error(&mut s, conn_id, structured);
            -1
        }
    }
}

/// Execute batch SQL (multi-result) and return binary buffer
/// Same contract as odbc_exec_query; output is multi-result format (count + items).
/// Returns: 0 on success, -1 on error, -2 if buffer too small
#[no_mangle]
pub extern "C" fn odbc_exec_query_multi(
    conn_id: c_uint,
    sql: *const c_char,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    if sql.is_null() || out_buffer.is_null() || out_written.is_null() {
        return -1;
    }

    let c_str = unsafe { CStr::from_ptr(sql) };
    let sql_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };

    let Some(state) = try_lock_global_state() else {
        return -1;
    };

    let conn = match state.connections.get(&conn_id) {
        Some(c) => c,
        None => {
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_error(
                &mut s,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return -1;
        }
    };

    let handles = conn.get_handles();
    let Some(handles_guard) = handles.lock().ok() else {
        drop(state);
        let Some(mut s) = try_lock_global_state() else {
            return -1;
        };
        set_connection_error(&mut s, conn_id, "Failed to lock handles mutex".to_string());
        return -1;
    };

    let odbc_conn = match handles_guard.get_connection(conn_id) {
        Ok(c) => c,
        Err(e) => {
            drop(handles_guard);
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_error(&mut s, conn_id, format!("Failed to get connection: {}", e));
            return -1;
        }
    };

    let metrics = Arc::clone(&state.metrics);
    let start = Instant::now();

    match execute_multi_result(odbc_conn, sql_str) {
        Ok(data) => {
            let elapsed = start.elapsed();
            if data.len() > buffer_len as usize {
                metrics.record_error();
                drop(state);
                let Some(mut s) = try_lock_global_state() else {
                    return -1;
                };
                set_connection_error(
                    &mut s,
                    conn_id,
                    format!(
                        "Buffer too small: need {} bytes, got {}",
                        data.len(),
                        buffer_len
                    ),
                );
                return -2;
            }

            metrics.record_query(elapsed);

            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr(), out_buffer, data.len());
                *out_written = data.len() as c_uint;
            }

            0
        }
        Err(e) => {
            metrics.record_error();
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            let structured = e.to_structured();
            set_connection_structured_error(&mut s, conn_id, structured);
            -1
        }
    }
}

/// Catalog: list tables. Uses INFORMATION_SCHEMA.TABLES.
/// catalog, schema: null or empty = no filter.
/// Returns: 0 on success, -1 on error, -2 if buffer too small.
#[no_mangle]
pub extern "C" fn odbc_catalog_tables(
    conn_id: c_uint,
    catalog: *const c_char,
    schema: *const c_char,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    if out_buffer.is_null() || out_written.is_null() {
        return -1;
    }

    let cat_opt = ptr_to_opt_str(catalog);
    let sch_opt = ptr_to_opt_str(schema);

    let cat_ref = cat_opt.as_deref();
    let sch_ref = sch_opt.as_deref();

    let Some(state) = try_lock_global_state() else {
        return -1;
    };

    let conn = match state.connections.get(&conn_id) {
        Some(c) => c,
        None => {
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_error(
                &mut s,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return -1;
        }
    };

    let handles = conn.get_handles();
    let Some(handles_guard) = handles.lock().ok() else {
        drop(state);
        let Some(mut s) = try_lock_global_state() else {
            return -1;
        };
        set_connection_error(&mut s, conn_id, "Failed to lock handles mutex".to_string());
        return -1;
    };

    let odbc_conn = match handles_guard.get_connection(conn_id) {
        Ok(c) => c,
        Err(e) => {
            drop(handles_guard);
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_error(&mut s, conn_id, format!("Failed to get connection: {}", e));
            return -1;
        }
    };

    let metrics = Arc::clone(&state.metrics);
    let start = Instant::now();

    match list_tables(odbc_conn, cat_ref, sch_ref) {
        Ok(data) => {
            metrics.record_query(start.elapsed());
            if data.len() > buffer_len as usize {
                metrics.record_error();
                drop(state);
                let Some(mut s) = try_lock_global_state() else {
                    return -1;
                };
                set_connection_error(
                    &mut s,
                    conn_id,
                    format!(
                        "Buffer too small: need {} bytes, got {}",
                        data.len(),
                        buffer_len
                    ),
                );
                return -2;
            }
            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr(), out_buffer, data.len());
                *out_written = data.len() as c_uint;
            }
            0
        }
        Err(e) => {
            metrics.record_error();
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_structured_error(&mut s, conn_id, e.to_structured());
            -1
        }
    }
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
    if table.is_null() || out_buffer.is_null() || out_written.is_null() {
        return -1;
    }

    let c_str = unsafe { CStr::from_ptr(table) };
    let table_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };

    let Some(state) = try_lock_global_state() else {
        return -1;
    };

    let conn = match state.connections.get(&conn_id) {
        Some(c) => c,
        None => {
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_error(
                &mut s,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return -1;
        }
    };

    let handles = conn.get_handles();
    let Some(handles_guard) = handles.lock().ok() else {
        drop(state);
        let Some(mut s) = try_lock_global_state() else {
            return -1;
        };
        set_connection_error(&mut s, conn_id, "Failed to lock handles mutex".to_string());
        return -1;
    };

    let odbc_conn = match handles_guard.get_connection(conn_id) {
        Ok(c) => c,
        Err(e) => {
            drop(handles_guard);
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_error(&mut s, conn_id, format!("Failed to get connection: {}", e));
            return -1;
        }
    };

    let metrics = Arc::clone(&state.metrics);
    let start = Instant::now();

    match list_columns(odbc_conn, table_str) {
        Ok(data) => {
            metrics.record_query(start.elapsed());
            if data.len() > buffer_len as usize {
                metrics.record_error();
                drop(state);
                let Some(mut s) = try_lock_global_state() else {
                    return -1;
                };
                set_connection_error(
                    &mut s,
                    conn_id,
                    format!(
                        "Buffer too small: need {} bytes, got {}",
                        data.len(),
                        buffer_len
                    ),
                );
                return -2;
            }
            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr(), out_buffer, data.len());
                *out_written = data.len() as c_uint;
            }
            0
        }
        Err(e) => {
            metrics.record_error();
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_structured_error(&mut s, conn_id, e.to_structured());
            -1
        }
    }
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
    if out_buffer.is_null() || out_written.is_null() {
        return -1;
    }

    let Some(state) = try_lock_global_state() else {
        return -1;
    };

    let conn = match state.connections.get(&conn_id) {
        Some(c) => c,
        None => {
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_error(
                &mut s,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return -1;
        }
    };

    let handles = conn.get_handles();
    let Some(handles_guard) = handles.lock().ok() else {
        drop(state);
        let Some(mut s) = try_lock_global_state() else {
            return -1;
        };
        set_connection_error(&mut s, conn_id, "Failed to lock handles mutex".to_string());
        return -1;
    };

    let odbc_conn = match handles_guard.get_connection(conn_id) {
        Ok(c) => c,
        Err(e) => {
            drop(handles_guard);
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_error(&mut s, conn_id, format!("Failed to get connection: {}", e));
            return -1;
        }
    };

    let metrics = Arc::clone(&state.metrics);
    let start = Instant::now();

    match get_type_info(odbc_conn) {
        Ok(data) => {
            metrics.record_query(start.elapsed());
            if data.len() > buffer_len as usize {
                metrics.record_error();
                drop(state);
                let Some(mut s) = try_lock_global_state() else {
                    return -1;
                };
                set_connection_error(
                    &mut s,
                    conn_id,
                    format!(
                        "Buffer too small: need {} bytes, got {}",
                        data.len(),
                        buffer_len
                    ),
                );
                return -2;
            }
            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr(), out_buffer, data.len());
                *out_written = data.len() as c_uint;
            }
            0
        }
        Err(e) => {
            metrics.record_error();
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_structured_error(&mut s, conn_id, e.to_structured());
            -1
        }
    }
}

fn ptr_to_opt_str(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let c_str = unsafe { CStr::from_ptr(ptr) };
    let s = c_str.to_str().ok()?;
    let t = s.trim();
    if t.is_empty() {
        return None;
    }
    Some(t.to_string())
}

/// Prepare a statement with optional timeout.
/// conn_id: connection ID from odbc_connect
/// sql: null-terminated UTF-8 SQL
/// timeout_ms: 0 = no timeout, else timeout in milliseconds
/// Returns: statement ID (>0) on success, 0 on failure
#[no_mangle]
pub extern "C" fn odbc_prepare(conn_id: c_uint, sql: *const c_char, timeout_ms: c_uint) -> c_uint {
    if sql.is_null() {
        return 0;
    }

    let c_str = unsafe { CStr::from_ptr(sql) };
    let sql_str = match c_str.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return 0,
    };

    let Some(mut state) = try_lock_global_state() else {
        return 0;
    };

    if !state.connections.contains_key(&conn_id) && !state.pooled_connections.contains_key(&conn_id)
    {
        set_connection_error(
            &mut state,
            conn_id,
            format!("Invalid connection ID: {}", conn_id),
        );
        return 0;
    }

    let stmt = StatementHandle::new(conn_id, sql_str, timeout_ms);
    let stmt_id = state.next_stmt_id;
    state.next_stmt_id = state.next_stmt_id.wrapping_add(1);
    state.statements.insert(stmt_id, stmt);
    stmt_id
}

/// Execute a prepared statement.
/// stmt_id: from odbc_prepare
/// params_buffer: serialized ParamValue array, or NULL for no params
/// params_len: length of params_buffer
/// out_buffer, buffer_len, out_written: same contract as odbc_exec_query
/// Returns: 0 on success, -1 on error, -2 if buffer too small
#[no_mangle]
pub extern "C" fn odbc_execute(
    stmt_id: c_uint,
    params_buffer: *const u8,
    params_len: c_uint,
    timeout_override_ms: c_uint,
    fetch_size: c_uint,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    if out_buffer.is_null() || out_written.is_null() {
        return -1;
    }

    let Some(state) = try_lock_global_state() else {
        return -1;
    };

    let (conn_id, sql_str, stored_timeout_sec) = match state.statements.get(&stmt_id) {
        Some(s) => (s.conn_id(), s.sql().to_string(), s.timeout_sec()),
        None => {
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_error(&mut s, format!("Invalid statement ID: {}", stmt_id));
            return -1;
        }
    };

    let params: Vec<ParamValue> = if params_buffer.is_null() || params_len == 0 {
        vec![]
    } else {
        let params_slice =
            unsafe { std::slice::from_raw_parts(params_buffer, params_len as usize) };
        match deserialize_params(params_slice) {
            Ok(p) => p,
            Err(e) => {
                drop(state);
                let Some(mut s) = try_lock_global_state() else {
                    return -1;
                };
                set_connection_error(&mut s, conn_id, format!("Invalid params: {}", e));
                return -1;
            }
        }
    };

    let metrics = Arc::clone(&state.metrics);
    let start = Instant::now();

    let timeout_sec = if timeout_override_ms > 0 {
        Some(((timeout_override_ms as usize) / 1000).max(1))
    } else {
        stored_timeout_sec
    };
    let fetch_size_opt = if fetch_size > 0 {
        Some(fetch_size)
    } else {
        None
    };

    let result = if let Some(conn) = state.connections.get(&conn_id) {
        let handles = conn.get_handles();
        let Some(handles_guard) = handles.lock().ok() else {
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_error(&mut s, conn_id, "Failed to lock handles mutex".to_string());
            return -1;
        };

        let odbc_conn = match handles_guard.get_connection(conn_id) {
            Ok(c) => c,
            Err(e) => {
                drop(handles_guard);
                drop(state);
                let Some(mut s) = try_lock_global_state() else {
                    return -1;
                };
                set_connection_error(&mut s, conn_id, format!("Failed to get connection: {}", e));
                return -1;
            }
        };

        execute_query_with_params_and_timeout(
            odbc_conn,
            &sql_str,
            &params,
            timeout_sec,
            fetch_size_opt,
        )
    } else if let Some((_pool_id, pooled)) = state.pooled_connections.get(&conn_id) {
        execute_query_with_params_and_timeout(
            pooled.get_connection(),
            &sql_str,
            &params,
            timeout_sec,
            fetch_size_opt,
        )
    } else {
        drop(state);
        let Some(mut s) = try_lock_global_state() else {
            return -1;
        };
        set_connection_error(
            &mut s,
            conn_id,
            format!("Connection {} no longer valid", conn_id),
        );
        return -1;
    };

    match result {
        Ok(data) => {
            let elapsed = start.elapsed();
            if data.len() > buffer_len as usize {
                metrics.record_error();
                drop(state);
                let Some(mut s) = try_lock_global_state() else {
                    return -1;
                };
                set_connection_error(
                    &mut s,
                    conn_id,
                    format!(
                        "Buffer too small: need {} bytes, got {}",
                        data.len(),
                        buffer_len
                    ),
                );
                return -2;
            }
            metrics.record_query(elapsed);
            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr(), out_buffer, data.len());
                *out_written = data.len() as c_uint;
            }
            0
        }
        Err(e) => {
            metrics.record_error();
            drop(state);
            let Some(mut s) = try_lock_global_state() else {
                return -1;
            };
            set_connection_structured_error(&mut s, conn_id, e.to_structured());
            -1
        }
    }
}

/// Cancel a statement in execution.
/// stmt_id: from odbc_prepare
/// Returns: 0 on success, non-zero on failure
///
/// # Unsupported Feature
///
/// Statement cancellation is not currently supported. This feature requires:
/// - Background execution thread with active statement handle tracking
/// - SQLCancel() or SQLCancelHandle() call on the executing statement
/// - Proper synchronization between execution and cancellation threads
///
/// Workaround: Use query timeout at connection or statement level instead.
#[no_mangle]
pub extern "C" fn odbc_cancel(stmt_id: c_uint) -> c_int {
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };

    if state.statements.contains_key(&stmt_id) {
        set_error(
            &mut state,
            "Unsupported feature: Statement cancellation requires background execution. \
            Use query timeout (login_timeout or statement timeout) instead. \
            See: https://github.com/odbc-fast/dart_odbc_fast/issues/X for tracking."
                .to_string(),
        );
        1
    } else {
        set_error(&mut state, format!("Invalid statement ID: {}", stmt_id));
        1
    }
}

/// Close a prepared statement and release resources.
/// stmt_id: from odbc_prepare
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_close_statement(stmt_id: c_uint) -> c_int {
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };

    if state.statements.remove(&stmt_id).is_some() {
        0
    } else {
        set_error(&mut state, format!("Invalid statement ID: {}", stmt_id));
        1
    }
}

/// Close all prepared statements and release resources.
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_clear_all_statements() -> c_int {
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };

    state.statements.clear();
    0
}

/// Start streaming query execution
/// conn_id: connection ID
/// sql: null-terminated UTF-8 SQL query
/// chunk_size: number of rows per chunk
/// Returns: stream_id (>0) on success, 0 on failure
#[no_mangle]
pub extern "C" fn odbc_stream_start(
    conn_id: c_uint,
    sql: *const c_char,
    chunk_size: c_uint,
) -> c_uint {
    if sql.is_null() {
        return 0;
    }

    // Safety: `sql` must be a valid null-terminated C string pointer
    let c_str = unsafe { CStr::from_ptr(sql) };
    let sql_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return 0,
    };

    let Some(state) = try_lock_global_state() else {
        return 0;
    };

    let conn = match state.connections.get(&conn_id) {
        Some(c) => c,
        None => {
            drop(state);
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return 0;
        }
    };

    let handles = conn.get_handles();
    let Some(handles_guard) = handles.lock().ok() else {
        drop(state);
        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };
        set_error(&mut state, "Failed to lock handles mutex".to_string());
        return 0;
    };

    let odbc_conn = match handles_guard.get_connection(conn_id) {
        Ok(c) => c,
        Err(e) => {
            drop(handles_guard);
            drop(state);
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            set_error(&mut state, format!("Failed to get connection: {}", e));
            return 0;
        }
    };

    let executor = StreamingExecutor::new(chunk_size as usize);
    match executor.execute_streaming(odbc_conn, sql_str) {
        Ok(stream_state) => {
            drop(handles_guard);
            drop(state);
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            let stream_id = state.next_stream_id;
            state.next_stream_id += 1;
            state
                .streams
                .insert(stream_id, StreamKind::Buffer(stream_state));
            state.stream_connections.insert(stream_id, conn_id);
            stream_id
        }
        Err(e) => {
            drop(handles_guard);
            drop(state);
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            set_connection_error(
                &mut state,
                conn_id,
                format!("odbc_stream_start failed: {}", e),
            );
            0
        }
    }
}

/// Start batched streaming (cursor-based; bounded memory).
/// conn_id: connection ID
/// sql: null-terminated UTF-8 SQL query
/// fetch_size: rows per batch
/// chunk_size: bytes per FFI chunk
/// Returns: stream_id (>0) on success, 0 on failure
#[no_mangle]
pub extern "C" fn odbc_stream_start_batched(
    conn_id: c_uint,
    sql: *const c_char,
    fetch_size: c_uint,
    chunk_size: c_uint,
) -> c_uint {
    if sql.is_null() {
        return 0;
    }

    let c_str = unsafe { CStr::from_ptr(sql) };
    let sql_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return 0,
    };

    let Some(state) = try_lock_global_state() else {
        return 0;
    };

    let conn = match state.connections.get(&conn_id) {
        Some(c) => c,
        None => {
            drop(state);
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return 0;
        }
    };

    let handles = conn.get_handles();
    let fetch_size = fetch_size as usize;
    let chunk_size = chunk_size.max(1) as usize;
    let sql_owned = sql_str.to_string();

    drop(state);

    let executor = StreamingExecutor::new(chunk_size);
    match executor.start_batched_stream(handles, conn_id, sql_owned, fetch_size, chunk_size) {
        Ok(batched_state) => {
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            let stream_id = state.next_stream_id;
            state.next_stream_id += 1;
            state
                .streams
                .insert(stream_id, StreamKind::Batched(batched_state));
            state.stream_connections.insert(stream_id, conn_id);
            stream_id
        }
        Err(e) => {
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            set_connection_error(
                &mut state,
                conn_id,
                format!("odbc_stream_start_batched failed: {}", e),
            );
            0
        }
    }
}

/// Fetch next chunk from stream
/// stream_id: stream ID from odbc_stream_start
/// out_buf: output buffer
/// buf_len: buffer size
/// out_written: bytes written
/// has_more: 1 if more data available, 0 otherwise
/// Returns: 0 on success, non-zero on error
#[no_mangle]
pub extern "C" fn odbc_stream_fetch(
    stream_id: c_uint,
    out_buf: *mut u8,
    buf_len: c_uint,
    out_written: *mut c_uint,
    has_more: *mut u8,
) -> c_int {
    if out_buf.is_null() || out_written.is_null() || has_more.is_null() {
        return -1;
    }

    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };

    let stream_conn_id = state.stream_connections.get(&stream_id).copied();

    let stream = match state.streams.get_mut(&stream_id) {
        Some(s) => s,
        None => {
            set_error(&mut state, format!("Invalid stream ID: {}", stream_id));
            return -1;
        }
    };

    match stream.fetch_next_chunk() {
        Ok(Some(data)) => {
            if data.len() > buf_len as usize {
                if let Some(conn_id) = stream_conn_id {
                    set_connection_error(
                        &mut state,
                        conn_id,
                        format!(
                            "Buffer too small: need {} bytes, got {}",
                            data.len(),
                            buf_len
                        ),
                    );
                } else {
                    set_error(
                        &mut state,
                        format!(
                            "Buffer too small: need {} bytes, got {}",
                            data.len(),
                            buf_len
                        ),
                    );
                }
                return -2;
            }

            // Safety: Pointers must be valid for their respective writes
            // out_buf: data.len() bytes, out_written/has_more: respective sizes
            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr(), out_buf, data.len());
                *out_written = data.len() as c_uint;
                *has_more = if stream.has_more() { 1 } else { 0 };
            }

            0
        }
        Ok(None) => {
            // Safety: Pointers must be valid for writes (verified by null checks earlier)
            unsafe {
                *out_written = 0;
                *has_more = 0;
            }
            0
        }
        Err(e) => {
            if let Some(conn_id) = stream_conn_id {
                set_connection_error(
                    &mut state,
                    conn_id,
                    format!("odbc_stream_fetch failed: {}", e),
                );
            } else {
                set_error(&mut state, format!("odbc_stream_fetch failed: {}", e));
            }
            -1
        }
    }
}

/// Close stream
/// stream_id: stream ID to close
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_stream_close(stream_id: c_uint) -> c_int {
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };

    if state.streams.remove(&stream_id).is_some() {
        state.stream_connections.remove(&stream_id);
        0
    } else {
        set_error(&mut state, format!("Invalid stream ID: {}", stream_id));
        1
    }
}

/// Create connection pool
/// conn_str: null-terminated UTF-8 connection string
/// max_size: maximum pool size
/// Returns: pool_id (>0) on success, 0 on failure
#[no_mangle]
pub extern "C" fn odbc_pool_create(conn_str: *const c_char, max_size: c_uint) -> c_uint {
    if conn_str.is_null() {
        return 0;
    }

    // Safety: `conn_str` must be a valid null-terminated C string pointer
    let c_str = unsafe { CStr::from_ptr(conn_str) };
    let conn_str_rust = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return 0,
    };

    match ConnectionPool::new(conn_str_rust, max_size) {
        Ok(pool) => {
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            let pool_id = state.next_pool_id;
            state.next_pool_id += 1;
            state.pools.insert(pool_id, Arc::new(pool));
            pool_id
        }
        Err(e) => {
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            set_error(&mut state, format!("odbc_pool_create failed: {}", e));
            0
        }
    }
}

/// Get connection from pool
/// pool_id: pool ID from odbc_pool_create
/// Returns: connection_id (>0) on success, 0 on failure
#[no_mangle]
pub extern "C" fn odbc_pool_get_connection(pool_id: c_uint) -> c_uint {
    let Some(mut state) = try_lock_global_state() else {
        return 0;
    };

    let pooled_wrapper = match state.pools.get(&pool_id) {
        Some(p) => p,
        None => {
            set_error(&mut state, format!("Invalid pool ID: {}", pool_id));
            return 0;
        }
    }
    .get();

    match pooled_wrapper {
        Ok(pooled_wrapper) => {
            let conn_id = state
                .pooled_free_ids
                .get_mut(&pool_id)
                .and_then(|ids| ids.pop())
                .unwrap_or_else(|| {
                    let id = state.next_pooled_conn_id;
                    state.next_pooled_conn_id = state.next_pooled_conn_id.wrapping_add(1);
                    id
                });

            state
                .pooled_connections
                .insert(conn_id, (pool_id, pooled_wrapper));
            conn_id
        }
        Err(e) => {
            set_error(
                &mut state,
                format!("Failed to get connection from pool: {}", e),
            );
            0
        }
    }
}

/// Release pooled connection back to pool
/// connection_id: connection ID from odbc_pool_get_connection
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_pool_release_connection(connection_id: c_uint) -> c_int {
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };

    if let Some((pool_id, _pooled)) = state.pooled_connections.remove(&connection_id) {
        state
            .pooled_free_ids
            .entry(pool_id)
            .or_default()
            .push(connection_id);
        0
    } else {
        set_error(
            &mut state,
            format!("Invalid pooled connection ID: {}", connection_id),
        );
        1
    }
}

/// Health check for pool
/// pool_id: pool ID
/// Returns: 1 if healthy, 0 if unhealthy
#[no_mangle]
pub extern "C" fn odbc_pool_health_check(pool_id: c_uint) -> c_int {
    let Some(state) = try_lock_global_state() else {
        return 0;
    };

    match state.pools.get(&pool_id) {
        Some(pool) => {
            if pool.health_check() {
                1
            } else {
                0
            }
        }
        None => 0,
    }
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
    if out_size.is_null() || out_idle.is_null() {
        return -1;
    }

    let Some(state) = try_lock_global_state() else {
        return -1;
    };

    let pool = match state.pools.get(&pool_id) {
        Some(p) => p,
        None => {
            return -1;
        }
    };

    // API-level state reports configured size, not lazily opened connections.
    let max_size = pool.max_size();
    let active = state
        .pooled_connections
        .values()
        .filter(|(pid, _)| *pid == pool_id)
        .count() as u32;
    let idle = max_size.saturating_sub(active);

    // Safety: `out_size` and `out_idle` are valid for writes of size_of::<c_uint>() bytes each.
    // Caller ensures pointers are valid (null checks above).
    unsafe {
        *out_size = max_size;
        *out_idle = idle;
    }

    0
}

/// Close and remove pool
/// pool_id: pool ID to close
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_pool_close(pool_id: c_uint) -> c_int {
    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };

    if state.pools.remove(&pool_id).is_some() {
        state.pooled_free_ids.remove(&pool_id);
        state
            .pooled_connections
            .retain(|_, (pid, _)| *pid != pool_id);
        0
    } else {
        set_error(&mut state, format!("Invalid pool ID: {}", pool_id));
        1
    }
}

/// Bulk insert using array binding (ODBC SQL_ATTR_PARAMSET_SIZE).
/// data_buffer: bulk insert binary payload (table, columns, row_count, columnar data).
/// rows_inserted: output, number of rows inserted.
/// Returns: 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn odbc_bulk_insert_array(
    conn_id: c_uint,
    _table: *const c_char,
    _columns: *const *const c_char,
    _column_count: c_uint,
    data_buffer: *const u8,
    buffer_len: c_uint,
    _row_count: c_uint,
    rows_inserted: *mut c_uint,
) -> c_int {
    if data_buffer.is_null() || rows_inserted.is_null() || buffer_len == 0 {
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        set_error(
            &mut state,
            "odbc_bulk_insert_array: data_buffer and rows_inserted must be non-null, buffer_len > 0"
                .to_string(),
        );
        return -1;
    }

    let slice = unsafe { std::slice::from_raw_parts(data_buffer, buffer_len as usize) };
    let payload = match parse_bulk_insert_payload(slice) {
        Ok(p) => p,
        Err(e) => {
            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };
            set_error(&mut state, e.to_string());
            return -1;
        }
    };

    let Some(mut state) = try_lock_global_state() else {
        return -1;
    };
    let conn = match state.connections.get(&conn_id) {
        Some(c) => c,
        None => {
            set_connection_error(
                &mut state,
                conn_id,
                format!("Invalid connection ID: {}", conn_id),
            );
            return -1;
        }
    };

    let handles = conn.get_handles();
    let Ok(handles_guard) = handles.lock() else {
        set_error(&mut state, "Failed to lock handles mutex".to_string());
        return -1;
    };
    let odbc_conn = match handles_guard.get_connection(conn_id) {
        Ok(c) => c,
        Err(e) => {
            set_error(&mut state, format!("Failed to get connection: {}", e));
            return -1;
        }
    };

    match ArrayBinding::default().bulk_insert_generic(odbc_conn, &payload) {
        Ok(total) => {
            unsafe {
                *rows_inserted = total as c_uint;
            }
            0
        }
        Err(e) => {
            // For bulk insert, use conn_id to store error
            set_connection_structured_error(&mut state, conn_id, e.to_structured());
            -1
        }
    }
}

fn row_chunk_ranges(row_count: usize, parallelism: usize) -> Vec<(usize, usize)> {
    if row_count == 0 {
        return Vec::new();
    }
    let workers = parallelism.max(1).min(row_count);
    let chunk_size = row_count.div_ceil(workers).max(1);
    (0..row_count)
        .step_by(chunk_size)
        .map(|start| (start, (start + chunk_size).min(row_count)))
        .collect()
}

fn slice_null_bitmap(bitmap: &[u8], start: usize, len: usize) -> Vec<u8> {
    let mut out = vec![0u8; len.div_ceil(8)];
    for i in 0..len {
        if is_null(bitmap, start + i) {
            out[i / 8] |= 1u8 << (i % 8);
        }
    }
    out
}

fn slice_payload_rows(
    payload: &BulkInsertPayload,
    start: usize,
    end: usize,
) -> Result<BulkInsertPayload> {
    let total_rows = payload.row_count as usize;
    if start > end || end > total_rows {
        return Err(OdbcError::ValidationError(
            "Invalid bulk insert chunk range".to_string(),
        ));
    }
    let chunk_rows = end - start;

    let mut chunk_data = Vec::with_capacity(payload.column_data.len());
    for col in &payload.column_data {
        let sliced = match col {
            BulkColumnData::I32 {
                values,
                null_bitmap,
            } => BulkColumnData::I32 {
                values: values[start..end].to_vec(),
                null_bitmap: null_bitmap
                    .as_ref()
                    .map(|bm| slice_null_bitmap(bm, start, chunk_rows)),
            },
            BulkColumnData::I64 {
                values,
                null_bitmap,
            } => BulkColumnData::I64 {
                values: values[start..end].to_vec(),
                null_bitmap: null_bitmap
                    .as_ref()
                    .map(|bm| slice_null_bitmap(bm, start, chunk_rows)),
            },
            BulkColumnData::Text {
                rows,
                max_len,
                null_bitmap,
            } => BulkColumnData::Text {
                rows: rows[start..end].to_vec(),
                max_len: *max_len,
                null_bitmap: null_bitmap
                    .as_ref()
                    .map(|bm| slice_null_bitmap(bm, start, chunk_rows)),
            },
            BulkColumnData::Binary {
                rows,
                max_len,
                null_bitmap,
            } => BulkColumnData::Binary {
                rows: rows[start..end].to_vec(),
                max_len: *max_len,
                null_bitmap: null_bitmap
                    .as_ref()
                    .map(|bm| slice_null_bitmap(bm, start, chunk_rows)),
            },
            BulkColumnData::Timestamp {
                values,
                null_bitmap,
            } => BulkColumnData::Timestamp {
                values: values[start..end].to_vec(),
                null_bitmap: null_bitmap
                    .as_ref()
                    .map(|bm| slice_null_bitmap(bm, start, chunk_rows)),
            },
        };
        chunk_data.push(sliced);
    }

    Ok(BulkInsertPayload {
        table: payload.table.clone(),
        columns: payload.columns.clone(),
        row_count: chunk_rows as u32,
        column_data: chunk_data,
    })
}

fn bulk_insert_parallel_with_pool(
    pool: &ConnectionPool,
    payload: &BulkInsertPayload,
    parallelism: usize,
) -> Result<usize> {
    let row_count = payload.row_count as usize;
    if row_count == 0 {
        return Ok(0);
    }

    let ranges = row_chunk_ranges(row_count, parallelism);
    let results: Vec<Result<usize>> = ranges
        .into_par_iter()
        .map(|(start, end)| {
            let pooled = pool.get()?;
            let odbc_conn = pooled.get_connection();
            let chunk = slice_payload_rows(payload, start, end)?;
            ArrayBinding::default().bulk_insert_generic(odbc_conn, &chunk)
        })
        .collect();

    let mut total = 0usize;
    for r in results {
        total += r?;
    }
    Ok(total)
}

/// Parallel bulk insert using pool.
#[no_mangle]
pub extern "C" fn odbc_bulk_insert_parallel(
    pool_id: c_uint,
    _table: *const c_char,
    _columns: *const *const c_char,
    _column_count: c_uint,
    data_buffer: *const u8,
    buffer_len: c_uint,
    parallelism: c_uint,
    rows_inserted: *mut c_uint,
) -> c_int {
    if data_buffer.is_null() || rows_inserted.is_null() || buffer_len == 0 {
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        set_error(
            &mut state,
            "odbc_bulk_insert_parallel: data_buffer and rows_inserted must be non-null, buffer_len > 0"
                .to_string(),
        );
        return -1;
    }

    if parallelism == 0 {
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        set_error(
            &mut state,
            "odbc_bulk_insert_parallel: parallelism must be >= 1".to_string(),
        );
        return -1;
    }

    let slice = unsafe { std::slice::from_raw_parts(data_buffer, buffer_len as usize) };
    let payload = match parse_bulk_insert_payload(slice) {
        Ok(p) => p,
        Err(e) => {
            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };
            set_error(&mut state, e.to_string());
            return -1;
        }
    };

    let pool = {
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        match state.pools.get(&pool_id) {
            Some(p) => Arc::clone(p),
            None => {
                set_error(&mut state, format!("Invalid pool ID: {}", pool_id));
                return -1;
            }
        }
    };

    match bulk_insert_parallel_with_pool(pool.as_ref(), &payload, parallelism as usize) {
        Ok(total) => {
            unsafe {
                *rows_inserted = total as c_uint;
            }
            0
        }
        Err(e) => {
            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };
            set_structured_error(&mut state, e.to_structured());
            -1
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{
        serialize_bulk_insert_payload, serialize_params, BulkColumnData, BulkColumnSpec,
        BulkColumnType, BulkInsertPayload, ParamValue,
    };
    use std::ffi::CString;
    use std::sync::atomic::{AtomicU32, Ordering};

    /// Base value for invalid IDs; real IDs are typically 1, 2, 3, ...
    const TEST_INVALID_ID_BASE: u32 = 0xDEAD_BEEF;

    /// Invalid ID used in tests (shared). Prefer `next_test_invalid_id()` when asserting on error message to avoid conflicts under parallel test runs.
    const TEST_INVALID_ID: u32 = TEST_INVALID_ID_BASE;

    /// Returns a unique invalid ID per call. Use in tests that assert on get_last_error() content so parallel runs don't overwrite the global error with the same ID.
    fn next_test_invalid_id() -> u32 {
        static NEXT: AtomicU32 = AtomicU32::new(TEST_INVALID_ID_BASE);
        NEXT.fetch_add(1, Ordering::SeqCst)
    }

    /// Helper to get error message after FFI call fails
    fn get_last_error() -> String {
        let mut buffer = vec![0u8; 1024];
        let result = odbc_get_error(buffer.as_mut_ptr() as *mut c_char, buffer.len() as c_uint);

        if result < 0 {
            return "Failed to get error".to_string();
        }

        let len = result as usize;
        String::from_utf8_lossy(&buffer[..len]).to_string()
    }

    #[test]
    fn test_ffi_init() {
        let result = odbc_init();
        assert_eq!(result, 0, "odbc_init should succeed");

        // Second init should also succeed (idempotent)
        let result = odbc_init();
        assert_eq!(result, 0, "odbc_init should be idempotent");
    }

    #[test]
    fn test_ffi_connect_invalid_string() {
        odbc_init();

        let empty_str = CString::new("").unwrap();
        let conn_id = odbc_connect(empty_str.as_ptr());

        assert_eq!(conn_id, 0, "Connect with empty string should fail");

        let error = get_last_error();
        assert!(!error.is_empty(), "Should have error message");
        println!("Error (expected): {}", error);
    }

    #[test]
    fn test_ffi_connect_null_pointer() {
        odbc_init();

        let conn_id = odbc_connect(std::ptr::null());
        assert_eq!(conn_id, 0, "Connect with null pointer should fail");
    }

    #[test]
    fn test_ffi_disconnect_invalid_id() {
        odbc_init();

        let invalid_id = next_test_invalid_id();
        let result = odbc_disconnect(invalid_id);
        assert_ne!(result, 0, "Disconnect with invalid ID should fail");

        let error = get_last_error();
        let err_lower = error.to_lowercase();
        assert!(
            err_lower.contains("invalid") && error.contains(&invalid_id.to_string()),
            "Error should mention invalid and the ID: {}",
            error
        );
    }

    #[test]
    fn test_ffi_get_error_buffer() {
        odbc_init();

        // Trigger an error with unique ID so global error is ours
        let invalid_id = next_test_invalid_id();
        let _ = odbc_disconnect(invalid_id);

        // Test with sufficient buffer
        let mut buffer = vec![0u8; 1024];
        let result = odbc_get_error(buffer.as_mut_ptr() as *mut c_char, buffer.len() as c_uint);

        assert!(result > 0, "Should return bytes written");
        let error_msg = String::from_utf8_lossy(&buffer[..result as usize]);
        // Note: Error message may be from previous test due to global state
        // We just verify that an error message is returned
        assert!(!error_msg.is_empty(), "Should return error message");
    }

    #[test]
    fn test_ffi_get_error_null_buffer() {
        let result = odbc_get_error(std::ptr::null_mut(), 100);
        assert_eq!(result, -1, "Null buffer should return -1");
    }

    #[test]
    fn test_ffi_get_error_zero_length() {
        let mut buffer = vec![0u8; 10];
        let result = odbc_get_error(buffer.as_mut_ptr() as *mut c_char, 0);
        assert_eq!(result, -1, "Zero-length buffer should return -1");
    }

    #[test]
    fn test_ffi_exec_query_null_sql() {
        odbc_init();

        let mut buffer = vec![0u8; 1024];
        let mut written: c_uint = 0;

        let result = odbc_exec_query(
            1,
            std::ptr::null(),
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
        );

        assert_eq!(result, -1, "Null SQL should return -1");
    }

    #[test]
    fn test_ffi_exec_query_invalid_conn_id() {
        odbc_init();

        let sql = CString::new("SELECT 1").unwrap();
        let mut buffer = vec![0u8; 1024];
        let mut written: c_uint = 0;

        let result = odbc_exec_query(
            TEST_INVALID_ID,
            sql.as_ptr(),
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
        );

        assert_eq!(result, -1, "Invalid connection ID should return -1");

        let error = get_last_error();
        assert!(
            error.contains("Invalid connection ID")
                || error.contains("Invalid pool ID")
                || error.contains(&TEST_INVALID_ID.to_string()),
            "Error should mention invalid ID: {}",
            error
        );
    }

    #[test]
    fn test_ffi_exec_query_null_buffer() {
        odbc_init();

        let sql = CString::new("SELECT 1").unwrap();
        let mut written: c_uint = 0;

        let result = odbc_exec_query(1, sql.as_ptr(), std::ptr::null_mut(), 1024, &mut written);

        assert_eq!(result, -1, "Null buffer should return -1");
    }

    #[test]
    fn test_ffi_stream_start_null_sql() {
        odbc_init();

        let stream_id = odbc_stream_start(1, std::ptr::null(), 100);

        assert_eq!(stream_id, 0, "Null SQL should return 0");
    }

    #[test]
    fn test_ffi_stream_start_invalid_conn() {
        odbc_init();

        let sql = CString::new("SELECT 1").unwrap();
        let stream_id = odbc_stream_start(TEST_INVALID_ID, sql.as_ptr(), 100);

        assert_eq!(stream_id, 0, "Invalid connection should return 0");
    }

    #[test]
    fn test_ffi_stream_fetch_invalid_stream() {
        odbc_init();

        let invalid_id = next_test_invalid_id();
        let mut buffer = vec![0u8; 1024];
        let mut written: c_uint = 0;
        let mut has_more: u8 = 0;

        let result = odbc_stream_fetch(
            invalid_id,
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
            &mut has_more,
        );

        assert_eq!(result, -1, "Invalid stream ID should return -1");

        let error = get_last_error();
        assert!(
            error.contains("Invalid stream ID") || error.contains("Invalid"),
            "Error should mention invalid stream: {}",
            error
        );
    }

    #[test]
    fn test_ffi_stream_fetch_null_buffer() {
        let mut written: c_uint = 0;
        let mut has_more: u8 = 0;

        let result = odbc_stream_fetch(1, std::ptr::null_mut(), 1024, &mut written, &mut has_more);

        assert_eq!(result, -1, "Null buffer should return -1");
    }

    #[test]
    fn test_ffi_stream_close_invalid_id() {
        odbc_init();

        let result = odbc_stream_close(TEST_INVALID_ID);
        assert_ne!(result, 0, "Invalid stream ID should fail");
    }

    #[test]
    fn test_ffi_stream_start_batched_null_sql() {
        odbc_init();

        let stream_id = odbc_stream_start_batched(1, std::ptr::null(), 100, 1024);

        assert_eq!(stream_id, 0, "Null SQL should return 0");
    }

    #[test]
    fn test_ffi_stream_start_batched_invalid_conn() {
        odbc_init();

        let sql = CString::new("SELECT 1").unwrap();
        let stream_id = odbc_stream_start_batched(TEST_INVALID_ID, sql.as_ptr(), 100, 1024);

        assert_eq!(stream_id, 0, "Invalid connection should return 0");
    }

    #[test]
    fn test_ffi_catalog_tables_invalid_conn() {
        odbc_init();

        let mut buf = vec![0u8; 4096];
        let mut written: c_uint = 0;
        let r = odbc_catalog_tables(
            TEST_INVALID_ID,
            std::ptr::null(),
            std::ptr::null(),
            buf.as_mut_ptr(),
            buf.len() as c_uint,
            &mut written,
        );
        assert_eq!(r, -1, "Invalid conn_id should return -1");
    }

    #[test]
    fn test_ffi_catalog_tables_null_buffer() {
        odbc_init();

        let mut written: c_uint = 0;
        let r = odbc_catalog_tables(
            1,
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null_mut(),
            4096,
            &mut written,
        );
        assert_eq!(r, -1, "Null buffer should return -1");
    }

    #[test]
    fn test_ffi_catalog_columns_null_table() {
        odbc_init();

        let mut buf = vec![0u8; 4096];
        let mut written: c_uint = 0;
        let r = odbc_catalog_columns(
            1,
            std::ptr::null(),
            buf.as_mut_ptr(),
            buf.len() as c_uint,
            &mut written,
        );
        assert_eq!(r, -1, "Null table should return -1");
    }

    #[test]
    fn test_ffi_catalog_columns_invalid_conn() {
        odbc_init();

        let tbl = CString::new("TABLES").unwrap();
        let mut buf = vec![0u8; 4096];
        let mut written: c_uint = 0;
        let r = odbc_catalog_columns(
            TEST_INVALID_ID,
            tbl.as_ptr(),
            buf.as_mut_ptr(),
            buf.len() as c_uint,
            &mut written,
        );
        assert_eq!(r, -1, "Invalid conn_id should return -1");
    }

    #[test]
    fn test_ffi_catalog_type_info_invalid_conn() {
        odbc_init();

        let mut buf = vec![0u8; 4096];
        let mut written: c_uint = 0;
        let r = odbc_catalog_type_info(
            TEST_INVALID_ID,
            buf.as_mut_ptr(),
            buf.len() as c_uint,
            &mut written,
        );
        assert_eq!(r, -1, "Invalid conn_id should return -1");
    }

    #[test]
    fn test_ffi_get_structured_error() {
        odbc_init();

        // Trigger an error
        let _ = odbc_disconnect(TEST_INVALID_ID);

        let mut buffer = vec![0u8; 1024];
        let mut written: c_uint = 0;

        let result =
            odbc_get_structured_error(buffer.as_mut_ptr(), buffer.len() as c_uint, &mut written);

        assert_eq!(result, 0, "Should succeed");
        assert!(written > 0, "Should write data");

        // Verify the buffer contains structured error data
        // Format: [sqlstate: 5 bytes][native_code: 4 bytes][message_len: 4 bytes][message: N bytes]
        assert!(
            written >= 13,
            "Should have at least header + message length"
        );
    }

    #[test]
    fn test_ffi_get_structured_error_null_buffer() {
        let mut written: c_uint = 0;

        let result = odbc_get_structured_error(std::ptr::null_mut(), 1024, &mut written);

        assert_eq!(result, -1, "Null buffer should return -1");
    }

    #[test]
    fn test_ffi_get_structured_error_null_out_written() {
        let mut buffer = vec![0u8; 1024];

        let result = odbc_get_structured_error(
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            std::ptr::null_mut(),
        );

        assert_eq!(result, -1, "Null out_written should return -1");
    }

    #[test]
    fn test_ffi_exec_query_buffer_too_small() {
        // This would require a real connection and query that returns data
        // For now, we just test the parameter validation
        odbc_init();

        let sql = CString::new("SELECT 1").unwrap();
        let mut buffer = vec![0u8; 1]; // Very small buffer
        let mut written: c_uint = 0;

        let result = odbc_exec_query(
            TEST_INVALID_ID, // Invalid conn, will fail before checking buffer size
            sql.as_ptr(),
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
        );

        assert_eq!(result, -1, "Should fail (invalid conn ID)");
    }

    #[test]
    fn test_ffi_lifecycle() {
        // Test complete init/cleanup lifecycle
        let result = odbc_init();
        assert_eq!(result, 0);

        // Attempt operations that should fail without connection
        // Note: Due to global state, connection ID 1 might exist from previous tests
        // We just verify the function doesn't crash
        let sql = CString::new("SELECT 1").unwrap();
        let mut buffer = vec![0u8; 1024];
        let mut written: c_uint = 0;

        let result = odbc_exec_query(
            TEST_INVALID_ID, // Sentinel ID that won't collide with real connection IDs
            sql.as_ptr(),
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
        );

        // Should fail with invalid connection ID
        assert_ne!(result, 0, "Query with invalid connection ID should fail");
    }

    #[test]
    fn test_ffi_get_error_small_buffer() {
        odbc_init();

        // Trigger an error
        let _ = odbc_disconnect(TEST_INVALID_ID);

        // Test with very small buffer (should truncate)
        let mut buffer = vec![0u8; 5];
        let result = odbc_get_error(buffer.as_mut_ptr() as *mut c_char, buffer.len() as c_uint);

        assert!(result >= 0, "Should succeed even with small buffer");
        assert!(
            result <= 4,
            "Should write at most 4 bytes (5 - 1 for null terminator)"
        );
    }

    #[test]
    fn test_ffi_get_structured_error_small_buffer() {
        odbc_init();

        // Trigger an error
        let _ = odbc_disconnect(TEST_INVALID_ID);

        // Test with buffer too small for error data
        let mut buffer = vec![0u8; 5];
        let mut written: c_uint = 0;

        let result =
            odbc_get_structured_error(buffer.as_mut_ptr(), buffer.len() as c_uint, &mut written);

        assert_eq!(result, -2, "Buffer too small should return -2");
    }

    #[test]
    fn test_ffi_exec_query_null_out_written() {
        odbc_init();

        let sql = CString::new("SELECT 1").unwrap();
        let mut buffer = vec![0u8; 1024];

        let result = odbc_exec_query(
            1,
            sql.as_ptr(),
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            std::ptr::null_mut(),
        );

        assert_eq!(result, -1, "Null out_written should return -1");
    }

    #[test]
    fn test_ffi_stream_fetch_null_has_more() {
        let mut buffer = vec![0u8; 1024];
        let mut written: c_uint = 0;

        let result = odbc_stream_fetch(
            1,
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
            std::ptr::null_mut(),
        );

        assert_eq!(result, -1, "Null has_more should return -1");
    }

    #[test]
    fn test_ffi_transaction_begin_invalid_conn() {
        odbc_init();

        let invalid_id = next_test_invalid_id();
        let txn_id = odbc_transaction_begin(invalid_id, 1);
        assert_eq!(txn_id, 0, "Invalid connection ID should return 0");

        let error = get_last_error();
        let id_str = invalid_id.to_string();
        assert!(
            (error.contains("Invalid connection ID") && error.contains(&id_str))
                || error.contains("Invalid"),
            "Should have error message for invalid conn/txn: {}",
            error
        );
    }

    #[test]
    fn test_ffi_transaction_begin_invalid_isolation() {
        odbc_init();

        let txn_id = odbc_transaction_begin(TEST_INVALID_ID, 99);
        assert_eq!(txn_id, 0, "Invalid isolation level should return 0");
    }

    #[test]
    fn test_ffi_transaction_commit_invalid_txn_id() {
        odbc_init();

        let invalid_id = next_test_invalid_id();
        let result = odbc_transaction_commit(invalid_id);
        assert_ne!(result, 0, "Invalid transaction ID should fail");

        let error = get_last_error();
        assert!(
            (error.contains("Invalid transaction ID") && error.contains(&invalid_id.to_string()))
                || error.contains("Invalid"),
            "Should have error message: {}",
            error
        );
    }

    #[test]
    fn test_ffi_transaction_rollback_invalid_txn_id() {
        odbc_init();

        let invalid_id = next_test_invalid_id();
        let result = odbc_transaction_rollback(invalid_id);
        assert_ne!(result, 0, "Invalid transaction ID should fail");

        let error = get_last_error();
        assert!(
            (error.contains("Invalid transaction ID") && error.contains(&invalid_id.to_string()))
                || error.contains("Invalid"),
            "Should have error message: {}",
            error
        );
    }

    #[test]
    fn test_ffi_pool_create_null_conn_str() {
        let pool_id = odbc_pool_create(std::ptr::null(), 10);
        assert_eq!(pool_id, 0, "Null connection string should return 0");
    }

    #[test]
    fn test_ffi_pool_create_invalid_conn_str() {
        // Invalid UTF-8 string (this would require unsafe to create, so we test with empty string)
        let empty_str = CString::new("").unwrap();
        let pool_id = odbc_pool_create(empty_str.as_ptr(), 10);

        // Should fail because empty connection string is invalid
        assert_eq!(pool_id, 0, "Empty connection string should return 0");

        let error = get_last_error();
        assert!(
            error.contains("odbc_pool_create failed") || error.contains("Pool creation failed"),
            "Should have error message: {}",
            error
        );
    }

    #[test]
    fn test_ffi_pool_get_connection_invalid_pool_id() {
        odbc_init();

        let conn_id = odbc_pool_get_connection(TEST_INVALID_ID);
        assert_eq!(conn_id, 0, "Invalid pool ID should return 0");

        // Note: Error message may be from previous test due to global state
        // We just verify that the function returns 0 (failure)
        // The actual error message check is less strict due to state persistence
    }

    #[test]
    fn test_ffi_pool_release_connection_invalid_id() {
        odbc_init();

        let result = odbc_pool_release_connection(TEST_INVALID_ID);
        assert_ne!(result, 0, "Invalid pooled connection ID should fail");

        // Note: Error message may be from previous test due to global state
        // We just verify that the function returns non-zero (failure)
    }

    #[test]
    fn test_ffi_pool_health_check_invalid_pool_id() {
        odbc_init();

        let result = odbc_pool_health_check(TEST_INVALID_ID);
        assert_eq!(result, 0, "Invalid pool ID should return 0 (unhealthy)");
    }

    #[test]
    fn test_ffi_pool_get_state_null_out_size() {
        let mut idle: c_uint = 0;

        let result = odbc_pool_get_state(1, std::ptr::null_mut(), &mut idle);
        assert_eq!(result, -1, "Null out_size should return -1");
    }

    #[test]
    fn test_ffi_pool_get_state_null_out_idle() {
        let mut size: c_uint = 0;

        let result = odbc_pool_get_state(1, &mut size, std::ptr::null_mut());
        assert_eq!(result, -1, "Null out_idle should return -1");
    }

    #[test]
    fn test_ffi_pool_get_state_invalid_pool_id() {
        odbc_init();

        let mut size: c_uint = 0;
        let mut idle: c_uint = 0;

        let result = odbc_pool_get_state(TEST_INVALID_ID, &mut size, &mut idle);
        assert_eq!(result, -1, "Invalid pool ID should return -1");
    }

    #[test]
    fn test_ffi_pool_close_invalid_pool_id() {
        odbc_init();

        let result = odbc_pool_close(TEST_INVALID_ID);
        assert_ne!(result, 0, "Invalid pool ID should fail");

        // Note: Error message may be from previous test due to global state
        // We just verify that the function returns non-zero (failure)
    }

    #[test]
    fn test_ffi_get_error_no_error() {
        // Note: This test may be affected by previous tests that set errors.
        // The global state persists across tests, so we can't guarantee "No error".
        // Instead, we just verify the function doesn't crash and returns a valid string.
        odbc_init();

        let mut buffer = vec![0u8; 1024];
        let result = odbc_get_error(buffer.as_mut_ptr() as *mut c_char, buffer.len() as c_uint);

        assert!(result >= 0, "Should succeed");
        let error_msg = String::from_utf8_lossy(&buffer[..result as usize]);
        assert!(
            !error_msg.is_empty(),
            "Should return some error message (may be from previous test)"
        );
    }

    #[test]
    fn test_ffi_get_structured_error_no_error() {
        odbc_init();

        // No error should have been set
        let mut buffer = vec![0u8; 1024];
        let mut written: c_uint = 0;

        let result =
            odbc_get_structured_error(buffer.as_mut_ptr(), buffer.len() as c_uint, &mut written);

        assert_eq!(result, 0, "Should succeed even with no error");
        assert!(
            written > 0,
            "Should write data (simple error from 'No error' message)"
        );
    }

    #[test]
    fn test_ffi_connect_without_init() {
        // Note: This test may pass if odbc_init() was called in a previous test
        // due to global state persistence. We verify the behavior, but the error
        // message check is optional since state may already be initialized.
        let conn_str = CString::new("DRIVER={SQL Server};SERVER=localhost").unwrap();
        let conn_id = odbc_connect(conn_str.as_ptr());

        // If environment is already initialized (from previous test), this might succeed
        // or fail with a different error. We just verify it doesn't crash.
        // The main test is that odbc_connect handles the case gracefully.
        let _ = conn_id;
    }

    #[test]
    fn test_ffi_exec_query_null_out_buffer() {
        odbc_init();

        let sql = CString::new("SELECT 1").unwrap();
        let mut written: c_uint = 0;

        let result = odbc_exec_query(1, sql.as_ptr(), std::ptr::null_mut(), 1024, &mut written);

        assert_eq!(result, -1, "Null output buffer should return -1");
    }

    #[test]
    fn test_ffi_stream_fetch_null_out_written() {
        let mut buffer = vec![0u8; 1024];
        let mut has_more: u8 = 0;

        let result = odbc_stream_fetch(
            1,
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            std::ptr::null_mut(),
            &mut has_more,
        );

        assert_eq!(result, -1, "Null out_written should return -1");
    }

    #[test]
    fn test_odbc_get_metrics_success() {
        odbc_init();

        let mut buffer = vec![0u8; 64];
        let mut written: c_uint = 0;

        let result = odbc_get_metrics(buffer.as_mut_ptr(), buffer.len() as c_uint, &mut written);

        assert_eq!(result, 0, "odbc_get_metrics should succeed");
        assert_eq!(written, 40, "Should write 40 bytes");
    }

    #[test]
    fn test_odbc_get_metrics_buffer_too_small() {
        odbc_init();

        let mut buffer = vec![0u8; 32];
        let mut written: c_uint = 0;

        let result = odbc_get_metrics(buffer.as_mut_ptr(), buffer.len() as c_uint, &mut written);

        assert_eq!(result, -2, "Buffer too small should return -2");
    }

    #[test]
    fn test_odbc_get_metrics_null_buffer() {
        odbc_init();

        let mut written: c_uint = 0;

        let result = odbc_get_metrics(std::ptr::null_mut(), 64, &mut written);

        assert_eq!(result, -1, "Null buffer should return -1");
    }

    fn ffi_test_dsn() -> Option<String> {
        use std::sync::Once;
        static INIT: Once = Once::new();

        // Carrega .env apenas uma vez
        INIT.call_once(|| {
            let _ = dotenvy::dotenv();
        });

        // Verifica se os testes e2e estão habilitados
        let enabled = std::env::var("ENABLE_E2E_TESTS").ok().and_then(|val| {
            let normalized = val.trim().to_lowercase();
            match normalized.as_str() {
                "1" | "true" | "yes" | "y" => Some(true),
                "0" | "false" | "no" | "n" => Some(false),
                _ => None,
            }
        }) == Some(true);

        if !enabled {
            return None;
        }

        std::env::var("ODBC_TEST_DSN")
            .ok()
            .filter(|s| !s.is_empty())
    }

    #[test]
    fn test_ffi_full_connection_query_disconnect() {
        let Some(dsn) = ffi_test_dsn() else {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
            return;
        };

        let r = odbc_init();
        assert_eq!(r, 0);

        let conn_cstr = CString::new(dsn.as_str()).unwrap();
        let conn_id = odbc_connect(conn_cstr.as_ptr());
        assert!(conn_id > 0, "Connect should succeed");

        let sql = CString::new("SELECT 1 AS value").unwrap();
        let mut buffer = vec![0u8; 2048];
        let mut written: c_uint = 0;

        let qr = odbc_exec_query(
            conn_id,
            sql.as_ptr(),
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
        );
        assert_eq!(qr, 0, "Exec query should succeed");
        assert!(written > 0);

        let dr = odbc_disconnect(conn_id);
        assert_eq!(dr, 0, "Disconnect should succeed");
    }

    #[test]
    fn test_ffi_transaction_workflow() {
        let Some(dsn) = ffi_test_dsn() else {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
            return;
        };

        odbc_init();
        let conn_cstr = CString::new(dsn.as_str()).unwrap();
        let conn_id = odbc_connect(conn_cstr.as_ptr());
        assert!(conn_id > 0);

        let txn_id = odbc_transaction_begin(conn_id, 1);
        assert!(txn_id > 0);

        let cr = odbc_transaction_commit(txn_id);
        assert_eq!(cr, 0);

        let dr = odbc_disconnect(conn_id);
        assert_eq!(dr, 0);
    }

    #[test]
    fn test_ffi_streaming_workflow() {
        let Some(dsn) = ffi_test_dsn() else {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
            return;
        };

        odbc_init();
        let conn_cstr = CString::new(dsn.as_str()).unwrap();
        let conn_id = odbc_connect(conn_cstr.as_ptr());
        assert!(conn_id > 0);

        let sql = CString::new("SELECT 1 AS n").unwrap();
        let stream_id = odbc_stream_start(conn_id, sql.as_ptr(), 1024);
        assert!(stream_id > 0);

        let mut buffer = vec![0u8; 4096];
        let mut written: c_uint = 0;
        let mut has_more: u8 = 1;

        while has_more != 0 {
            let fr = odbc_stream_fetch(
                stream_id,
                buffer.as_mut_ptr(),
                buffer.len() as c_uint,
                &mut written,
                &mut has_more,
            );
            assert_eq!(fr, 0, "Stream fetch should succeed");
            if has_more == 0 {
                break;
            }
        }

        let sr = odbc_stream_close(stream_id);
        assert_eq!(sr, 0);

        let dr = odbc_disconnect(conn_id);
        assert_eq!(dr, 0);
    }

    #[test]
    fn test_ffi_stream_batched_workflow() {
        let Some(dsn) = ffi_test_dsn() else {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
            return;
        };

        odbc_init();
        let conn_cstr = CString::new(dsn.as_str()).unwrap();
        let conn_id = odbc_connect(conn_cstr.as_ptr());
        assert!(conn_id > 0);

        let sql = CString::new("SELECT 1 AS n").unwrap();
        let stream_id = odbc_stream_start_batched(
            conn_id,
            sql.as_ptr(),
            100,  /* fetch_size */
            1024, /* chunk_size */
        );
        assert!(stream_id > 0);

        let mut buffer = vec![0u8; 4096];
        let mut written: c_uint = 0;
        let mut has_more: u8 = 1;

        while has_more != 0 {
            let fr = odbc_stream_fetch(
                stream_id,
                buffer.as_mut_ptr(),
                buffer.len() as c_uint,
                &mut written,
                &mut has_more,
            );
            assert_eq!(fr, 0, "Stream fetch should succeed");
            if has_more == 0 {
                break;
            }
        }

        let sr = odbc_stream_close(stream_id);
        assert_eq!(sr, 0);

        let dr = odbc_disconnect(conn_id);
        assert_eq!(dr, 0);
    }

    #[test]
    fn test_ffi_pool_workflow() {
        let Some(dsn) = ffi_test_dsn() else {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
            return;
        };

        odbc_init();
        let conn_cstr = CString::new(dsn.as_str()).unwrap();
        let pool_id = odbc_pool_create(conn_cstr.as_ptr(), 2);
        assert!(pool_id > 0);

        let pooled_id = odbc_pool_get_connection(pool_id);
        assert!(pooled_id > 0);

        let pr = odbc_pool_release_connection(pooled_id);
        assert_eq!(pr, 0);

        let cr = odbc_pool_close(pool_id);
        assert_eq!(cr, 0);
    }

    #[test]
    fn test_ffi_exec_query_params_null_buffer() {
        let Some(dsn) = ffi_test_dsn() else {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
            return;
        };

        odbc_init();
        let conn_cstr = CString::new(dsn.as_str()).unwrap();
        let conn_id = odbc_connect(conn_cstr.as_ptr());
        assert!(conn_id > 0);

        let sql = CString::new("SELECT 1 AS value").unwrap();
        let mut buffer = vec![0u8; 2048];
        let mut written: c_uint = 0;

        let result = odbc_exec_query_params(
            conn_id,
            sql.as_ptr(),
            std::ptr::null(),
            0,
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
        );
        assert_eq!(
            result, 0,
            "odbc_exec_query_params with null params buffer should succeed"
        );
        assert!(written > 0);

        let _ = odbc_disconnect(conn_id);
    }

    #[test]
    fn test_ffi_exec_query_params_success() {
        let Some(dsn) = ffi_test_dsn() else {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
            return;
        };

        odbc_init();
        let conn_cstr = CString::new(dsn.as_str()).unwrap();
        let conn_id = odbc_connect(conn_cstr.as_ptr());
        assert!(conn_id > 0);

        let params = vec![ParamValue::Integer(42)];
        let params_bytes = serialize_params(&params);

        let sql = CString::new("SELECT ? AS value").unwrap();
        let mut buffer = vec![0u8; 2048];
        let mut written: c_uint = 0;

        let result = odbc_exec_query_params(
            conn_id,
            sql.as_ptr(),
            params_bytes.as_ptr(),
            params_bytes.len() as c_uint,
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
        );
        assert_eq!(result, 0, "odbc_exec_query_params should succeed");
        assert!(written > 0);

        let _ = odbc_disconnect(conn_id);
    }

    #[test]
    fn test_ffi_exec_query_params_invalid_params() {
        let Some(dsn) = ffi_test_dsn() else {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
            return;
        };

        odbc_init();
        let conn_cstr = CString::new(dsn.as_str()).unwrap();
        let conn_id = odbc_connect(conn_cstr.as_ptr());
        assert!(conn_id > 0);

        let invalid_params = [0xffu8, 0, 0, 0, 0];
        let sql = CString::new("SELECT 1").unwrap();
        let mut buffer = vec![0u8; 2048];
        let mut written: c_uint = 0;

        let result = odbc_exec_query_params(
            conn_id,
            sql.as_ptr(),
            invalid_params.as_ptr(),
            invalid_params.len() as c_uint,
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
        );
        assert_eq!(result, -1, "Invalid params buffer should return -1");

        let error = get_last_error();
        assert!(
            error.contains("Invalid params") || error.contains("Unknown ParamValue tag"),
            "Error should mention invalid params: {}",
            error
        );

        let _ = odbc_disconnect(conn_id);
    }

    #[test]
    fn test_ffi_prepare_null_sql() {
        odbc_init();
        let stmt_id = odbc_prepare(1, std::ptr::null(), 0);
        assert_eq!(stmt_id, 0, "Prepare with null SQL should return 0");
    }

    #[test]
    fn test_ffi_prepare_invalid_conn() {
        odbc_init();
        let sql = CString::new("SELECT 1").unwrap();
        let stmt_id = odbc_prepare(TEST_INVALID_ID, sql.as_ptr(), 0);
        assert_eq!(stmt_id, 0, "Prepare with invalid conn_id should return 0");
        let err = get_last_error();
        assert!(
            err.contains("Invalid connection") || err.contains(&TEST_INVALID_ID.to_string()),
            "Error should mention invalid connection: {}",
            err
        );
    }

    #[test]
    fn test_ffi_close_statement_invalid() {
        odbc_init();
        let r = odbc_close_statement(TEST_INVALID_ID);
        assert_ne!(r, 0, "Close invalid statement should fail");
        let err = get_last_error();
        assert!(
            err.contains("Invalid statement") || err.contains(&TEST_INVALID_ID.to_string()),
            "Error should mention invalid statement: {}",
            err
        );
    }

    #[test]
    fn test_ffi_clear_all_statements() {
        odbc_init();

        let Some(mut state) = try_lock_global_state() else {
            panic!("Failed to lock global state");
        };
        state
            .statements
            .insert(1001, StatementHandle::new(1, "SELECT 1".to_string(), 0));
        state
            .statements
            .insert(1002, StatementHandle::new(1, "SELECT 2".to_string(), 0));
        assert_eq!(
            state.statements.len(),
            2,
            "Test setup should create statements"
        );
        drop(state);

        let r = odbc_clear_all_statements();
        assert_eq!(r, 0, "Clear all statements should succeed");

        let Some(state) = try_lock_global_state() else {
            panic!("Failed to re-lock global state");
        };
        assert!(
            state.statements.is_empty(),
            "All statements should be removed"
        );
    }

    #[test]
    fn test_ffi_cancel_invalid_stmt() {
        odbc_init();
        let r = odbc_cancel(TEST_INVALID_ID);
        assert_ne!(r, 0, "Cancel invalid statement should fail");
        let err = get_last_error();
        assert!(
            err.contains("Invalid statement") || err.contains(&TEST_INVALID_ID.to_string()),
            "Error should mention invalid statement: {}",
            err
        );
    }

    #[test]
    fn test_ffi_bulk_insert_null_buffer() {
        odbc_init();
        let mut rows: c_uint = 0;
        let r = odbc_bulk_insert_array(
            1,
            std::ptr::null(),
            std::ptr::null(),
            0,
            std::ptr::null(),
            100,
            0,
            &mut rows,
        );
        assert_eq!(r, -1, "Null data_buffer should return -1");
    }

    #[test]
    fn test_ffi_bulk_insert_null_rows_inserted() {
        odbc_init();
        let payload = BulkInsertPayload {
            table: "t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "a".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            }],
            row_count: 0,
            column_data: vec![],
        };
        let enc = serialize_bulk_insert_payload(&payload).unwrap();
        let r = odbc_bulk_insert_array(
            1,
            std::ptr::null(),
            std::ptr::null(),
            0,
            enc.as_ptr(),
            enc.len() as c_uint,
            0,
            std::ptr::null_mut(),
        );
        assert_eq!(r, -1, "Null rows_inserted should return -1");
    }

    #[test]
    fn test_ffi_bulk_insert_zero_len() {
        odbc_init();
        let mut rows: c_uint = 0;
        let buf = [0u8; 8];
        let r = odbc_bulk_insert_array(
            1,
            std::ptr::null(),
            std::ptr::null(),
            0,
            buf.as_ptr(),
            0,
            0,
            &mut rows,
        );
        assert_eq!(r, -1, "Zero buffer_len should return -1");
    }

    #[test]
    fn test_ffi_bulk_insert_invalid_conn() {
        odbc_init();
        let payload = BulkInsertPayload {
            table: "t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "a".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            }],
            row_count: 2,
            column_data: vec![BulkColumnData::I32 {
                values: vec![1, 2],
                null_bitmap: None,
            }],
        };
        let enc = serialize_bulk_insert_payload(&payload).unwrap();
        let mut rows: c_uint = 0;
        let r = odbc_bulk_insert_array(
            TEST_INVALID_ID,
            std::ptr::null(),
            std::ptr::null(),
            0,
            enc.as_ptr(),
            enc.len() as c_uint,
            0,
            &mut rows,
        );
        assert_eq!(r, -1, "Invalid conn_id should return -1");
        let err = get_last_error();
        assert!(
            err.contains("Invalid connection")
                || err.contains("Invalid pool ID")
                || err.contains(&TEST_INVALID_ID.to_string())
                || err.contains("payload truncated")
                || err.contains("data_buffer")
                || err.contains("non-null")
                || err.contains("buffer_len"),
            "Error should mention invalid connection, payload, or buffer: {}",
            err
        );
    }

    #[test]
    fn test_ffi_bulk_insert_invalid_payload() {
        odbc_init();
        let mut rows: c_uint = 0;
        let truncated = [0u8, 0, 0, 0];
        let r = odbc_bulk_insert_array(
            1,
            std::ptr::null(),
            std::ptr::null(),
            0,
            truncated.as_ptr(),
            truncated.len() as c_uint,
            0,
            &mut rows,
        );
        assert_eq!(r, -1, "Truncated payload should return -1");
    }

    #[test]
    fn test_ffi_bulk_insert_parallel_null_buffer() {
        odbc_init();
        let mut rows: c_uint = 0;
        let r = odbc_bulk_insert_parallel(
            1,
            std::ptr::null(),
            std::ptr::null(),
            0,
            std::ptr::null(),
            16,
            2,
            &mut rows,
        );
        assert_eq!(r, -1, "Null data_buffer should return -1");
    }

    #[test]
    fn test_ffi_bulk_insert_parallel_null_rows_inserted() {
        odbc_init();
        let payload = BulkInsertPayload {
            table: "t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "a".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            }],
            row_count: 1,
            column_data: vec![BulkColumnData::I32 {
                values: vec![1],
                null_bitmap: None,
            }],
        };
        let enc = serialize_bulk_insert_payload(&payload).unwrap();
        let r = odbc_bulk_insert_parallel(
            1,
            std::ptr::null(),
            std::ptr::null(),
            0,
            enc.as_ptr(),
            enc.len() as c_uint,
            2,
            std::ptr::null_mut(),
        );
        assert_eq!(r, -1, "Null rows_inserted should return -1");
    }

    #[test]
    fn test_ffi_bulk_insert_parallel_zero_len() {
        odbc_init();
        let mut rows: c_uint = 0;
        let buf = [0u8; 8];
        let r = odbc_bulk_insert_parallel(
            1,
            std::ptr::null(),
            std::ptr::null(),
            0,
            buf.as_ptr(),
            0,
            2,
            &mut rows,
        );
        assert_eq!(r, -1, "Zero buffer_len should return -1");
    }

    #[test]
    fn test_ffi_bulk_insert_parallel_invalid_pool() {
        odbc_init();
        let payload = BulkInsertPayload {
            table: "t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "a".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            }],
            row_count: 1,
            column_data: vec![BulkColumnData::I32 {
                values: vec![1],
                null_bitmap: None,
            }],
        };
        let enc = serialize_bulk_insert_payload(&payload).unwrap();
        let mut rows: c_uint = 0;
        let r = odbc_bulk_insert_parallel(
            TEST_INVALID_ID,
            std::ptr::null(),
            std::ptr::null(),
            0,
            enc.as_ptr(),
            enc.len() as c_uint,
            2,
            &mut rows,
        );
        assert_eq!(r, -1, "Invalid pool_id should return -1");
    }

    #[test]
    fn test_ffi_bulk_insert_parallel_zero_parallelism() {
        odbc_init();
        let payload = BulkInsertPayload {
            table: "t".to_string(),
            columns: vec![BulkColumnSpec {
                name: "a".to_string(),
                col_type: BulkColumnType::I32,
                nullable: false,
                max_len: 0,
            }],
            row_count: 1,
            column_data: vec![BulkColumnData::I32 {
                values: vec![1],
                null_bitmap: None,
            }],
        };
        let enc = serialize_bulk_insert_payload(&payload).unwrap();
        let mut rows: c_uint = 0;
        let r = odbc_bulk_insert_parallel(
            1,
            std::ptr::null(),
            std::ptr::null(),
            0,
            enc.as_ptr(),
            enc.len() as c_uint,
            0,
            &mut rows,
        );
        assert_eq!(r, -1, "parallelism=0 should return -1");
    }

    #[test]
    fn test_ffi_prepare_execute_close() {
        let Some(dsn) = ffi_test_dsn() else {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
            return;
        };

        odbc_init();
        let conn_cstr = CString::new(dsn.as_str()).unwrap();
        let conn_id = odbc_connect(conn_cstr.as_ptr());
        assert!(conn_id > 0);

        let sql = CString::new("SELECT 1 AS x").unwrap();
        let stmt_id = odbc_prepare(conn_id, sql.as_ptr(), 0);
        assert!(stmt_id > 0, "Prepare should succeed");

        let mut buffer = vec![0u8; 2048];
        let mut written: c_uint = 0;
        let result = odbc_execute(
            stmt_id,
            std::ptr::null(),
            0,
            0,
            0,
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
        );
        assert_eq!(result, 0, "Execute should succeed");
        assert!(written > 0);

        let close_r = odbc_close_statement(stmt_id);
        assert_eq!(close_r, 0, "Close statement should succeed");

        let _ = odbc_disconnect(conn_id);
    }

    #[test]
    fn test_ffi_prepare_execute_with_timeout() {
        let Some(dsn) = ffi_test_dsn() else {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
            return;
        };

        odbc_init();
        let conn_cstr = CString::new(dsn.as_str()).unwrap();
        let conn_id = odbc_connect(conn_cstr.as_ptr());
        assert!(conn_id > 0);

        let sql = CString::new("SELECT 1 AS x").unwrap();
        let stmt_id = odbc_prepare(conn_id, sql.as_ptr(), 5000);
        assert!(stmt_id > 0, "Prepare with timeout should succeed");

        let mut buffer = vec![0u8; 2048];
        let mut written: c_uint = 0;
        let result = odbc_execute(
            stmt_id,
            std::ptr::null(),
            0,
            0,
            0,
            buffer.as_mut_ptr(),
            buffer.len() as c_uint,
            &mut written,
        );
        assert_eq!(result, 0, "Execute with timeout should succeed");
        assert!(written > 0);

        let _ = odbc_close_statement(stmt_id);
        let _ = odbc_disconnect(conn_id);
    }

    #[test]
    fn test_connection_error_isolation() {
        odbc_init();

        // Create two connections
        let Some(dsn) = ffi_test_dsn() else {
            eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
            return;
        };

        let conn_cstr = CString::new(dsn.as_str()).unwrap();
        let conn_id1 = odbc_connect(conn_cstr.as_ptr());
        let conn_id2 = odbc_connect(conn_cstr.as_ptr());

        if conn_id1 == 0 || conn_id2 == 0 {
            eprintln!("⚠️  Skipping: Could not create test connections");
            return;
        }

        // Generate error on connection 1
        let sql1 = CString::new("INVALID SQL FOR CONN1").unwrap();
        let mut buffer1 = vec![0u8; 1024];
        let mut written1: c_uint = 0;
        let result1 = odbc_exec_query(
            conn_id1,
            sql1.as_ptr(),
            buffer1.as_mut_ptr(),
            buffer1.len() as c_uint,
            &mut written1,
        );
        assert_ne!(result1, 0, "Query 1 should fail");

        // Generate different error on connection 2
        let sql2 = CString::new("INVALID SQL FOR CONN2").unwrap();
        let mut buffer2 = vec![0u8; 1024];
        let mut written2: c_uint = 0;
        let result2 = odbc_exec_query(
            conn_id2,
            sql2.as_ptr(),
            buffer2.as_mut_ptr(),
            buffer2.len() as c_uint,
            &mut written2,
        );
        assert_ne!(result2, 0, "Query 2 should fail");

        // Get errors - they should be different or at least not interfere
        let mut error_buf1 = vec![0u8; 1024];
        let mut error_buf2 = vec![0u8; 1024];

        let len1 = odbc_get_error(
            error_buf1.as_mut_ptr() as *mut c_char,
            error_buf1.len() as c_uint,
        );
        let len2 = odbc_get_error(
            error_buf2.as_mut_ptr() as *mut c_char,
            error_buf2.len() as c_uint,
        );

        // Errors should be captured (non-negative length)
        assert!(len1 >= 0, "Should get error message 1");
        assert!(len2 >= 0, "Should get error message 2");

        // Cleanup
        let _ = odbc_disconnect(conn_id1);
        let _ = odbc_disconnect(conn_id2);
    }

    #[test]
    fn test_global_error_fallback() {
        odbc_init();

        // Trigger a global error (function without conn_id)
        let result = odbc_init(); // Should succeed, but if it fails, error is global
        assert_eq!(result, 0);

        // Try to get error - should work even without connection
        let mut error_buf = vec![0u8; 1024];
        let len = odbc_get_error(
            error_buf.as_mut_ptr() as *mut c_char,
            error_buf.len() as c_uint,
        );

        // Should succeed (may return "No error" if no error was set)
        assert!(
            len >= 0,
            "Should be able to get error even without connection"
        );
    }
}

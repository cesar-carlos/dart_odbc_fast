use crate::engine::{
    AsyncStreamStatus, AsyncStreamingState, BatchedStreamingState, OdbcConnection, OdbcEnvironment,
    StreamCopyResult, StreamState, Transaction,
};
pub(crate) use crate::error::Result;
use crate::plugins::PluginRegistry;
#[cfg(feature = "sqlserver-bcp")]
use std::collections::HashMap;
use std::os::raw::{c_int, c_uint};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use super::state;

pub const DEFAULT_FETCH_SIZE: c_uint = 100;
pub const DEFAULT_CHUNK_SIZE: c_uint = 1024;
const DEFAULT_METADATA_CACHE_SIZE: usize = 100;
const DEFAULT_METADATA_CACHE_TTL_SECS: u64 = 300;

/// Poll status codes for async stream.
pub(crate) const STREAM_ASYNC_STATUS_PENDING: c_int = 0;
pub(crate) const STREAM_ASYNC_STATUS_READY: c_int = 1;
pub(crate) const STREAM_ASYNC_STATUS_DONE: c_int = 2;
pub(crate) const STREAM_ASYNC_STATUS_ERROR: c_int = -1;
pub(crate) const STREAM_ASYNC_STATUS_CANCELLED: c_int = -2;

/// FFI return codes (Fase 1 - padronizacao). Documented for consistency; literals used at call sites.
#[allow(
    dead_code,
    reason = "Legacy FFI status constants kept for ABI docs; ODBC-ENG-424; remove by 2026-09-30."
)]
pub(crate) const FFI_OK: c_int = 0;
#[allow(
    dead_code,
    reason = "Legacy FFI status constants kept for ABI docs; ODBC-ENG-424; remove by 2026-09-30."
)]
pub(crate) const FFI_ERR: c_int = -1;
#[allow(
    dead_code,
    reason = "Legacy FFI status constants kept for ABI docs; ODBC-ENG-424; remove by 2026-09-30."
)]
pub(crate) const FFI_ERR_BUFFER_TOO_SMALL: c_int = -2;

/// Max attempts when allocating ID to avoid collision
pub(crate) const MAX_ID_ALLOC_ATTEMPTS: u32 = 1000;

pub(crate) enum StreamKind {
    Buffer(StreamState),
    Batched(BatchedStreamingState),
    AsyncBatched(AsyncStreamingState),
}

impl StreamKind {
    pub(crate) fn copy_next_chunk(&mut self, out: &mut [u8]) -> Result<StreamCopyResult> {
        match self {
            StreamKind::Buffer(s) => s.copy_next_chunk(out),
            StreamKind::Batched(s) => s.copy_next_chunk(out),
            StreamKind::AsyncBatched(s) => s.copy_next_chunk(out),
        }
    }

    pub(crate) fn cancel(&self) {
        match self {
            StreamKind::Batched(s) => s.request_cancel(),
            StreamKind::AsyncBatched(s) => s.request_cancel(),
            StreamKind::Buffer(_) => {}
        }
    }

    pub(crate) fn poll_status(&mut self) -> c_int {
        match self {
            StreamKind::AsyncBatched(s) => match s.poll_status() {
                AsyncStreamStatus::Pending => STREAM_ASYNC_STATUS_PENDING,
                AsyncStreamStatus::Ready => STREAM_ASYNC_STATUS_READY,
                AsyncStreamStatus::Done => STREAM_ASYNC_STATUS_DONE,
                AsyncStreamStatus::Cancelled => STREAM_ASYNC_STATUS_CANCELLED,
                AsyncStreamStatus::Error => STREAM_ASYNC_STATUS_ERROR,
            },
            StreamKind::Buffer(s) => {
                if s.has_more() {
                    STREAM_ASYNC_STATUS_READY
                } else {
                    STREAM_ASYNC_STATUS_DONE
                }
            }
            StreamKind::Batched(s) => {
                if s.has_more() {
                    STREAM_ASYNC_STATUS_READY
                } else {
                    STREAM_ASYNC_STATUS_DONE
                }
            }
        }
    }
}

/// Set out_written to 0 on error path when pointer is valid.
pub(crate) fn set_out_written_zero(out_written: *mut c_uint) {
    if !out_written.is_null() {
        // SAFETY: pointer is non-null (checked above); caller guarantees it
        // is writable for the duration of this FFI call.
        unsafe { *out_written = 0 };
    }
}

pub(crate) fn set_out_written_needed(out_written: *mut c_uint, needed: usize) {
    if !out_written.is_null() {
        // SAFETY: pointer is non-null (checked above); caller guarantees it
        // is writable for the duration of this FFI call.
        unsafe { *out_written = needed.min(c_uint::MAX as usize) as c_uint };
    }
}

pub(crate) fn write_ffi_output_buffer(
    data: &[u8],
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    if out_buffer.is_null() || out_written.is_null() {
        return FFI_ERR;
    }
    if data.len() > buffer_len as usize {
        set_out_written_needed(out_written, data.len());
        return FFI_ERR_BUFFER_TOO_SMALL;
    }

    // SAFETY: null pointers were rejected above, `data.len() <= buffer_len`,
    // and `u8` has no alignment requirement.
    unsafe {
        std::ptr::copy_nonoverlapping(data.as_ptr(), out_buffer, data.len());
        *out_written = data.len() as c_uint;
    }
    FFI_OK
}

pub(crate) fn write_connection_output_buffer(
    state: &mut GlobalState,
    conn_id: u32,
    data: &[u8],
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    if data.len() > buffer_len as usize {
        set_connection_error(
            state,
            conn_id,
            format!(
                "Buffer too small: need {} bytes, got {}",
                data.len(),
                buffer_len
            ),
        );
    }
    write_ffi_output_buffer(data, out_buffer, buffer_len, out_written)
}

pub(crate) struct GlobalState {
    pub(crate) env: Option<Arc<Mutex<OdbcEnvironment>>>,
    /// Connection strings for native BCP path (conn_id -> conn_str).
    #[cfg(feature = "sqlserver-bcp")]
    pub(crate) connection_strings: HashMap<u32, String>,
    //
    // Fields hoisted out of this struct into dedicated locks/atomics.
    // Access via helpers in [`crate::ffi::state`]:
    //
    // - `metrics` → [`state::ffi_metrics()`] (lock-free Arc, sprint 3)
    // - `audit_logger` → [`state::ffi_audit_logger()`] (lock-free Arc, sprint 3)
    // - `connection_errors` → [`state::connection_errors_read`] / `_write`
    //   (dedicated `RwLock`, sprint 3)
    // - `async_requests` → [`lock_async_requests()`] (dedicated `Mutex`, sprint 3)
    // - `last_error` / `last_structured_error` → [`state::legacy_global_error_read`]
    //   / `_write` and the convenience setters (dedicated `RwLock`,
    //   sprint 4 follow-up A2)
    // - `connections` → [`state::connections_read`] / `_write`
    //   (dedicated `RwLock`, sprint 4 follow-up)
    // - `metadata_cache` → [`state::metadata_cache_read`] / `_write`
    //   (dedicated `RwLock`; the cache already serialises its own LRU maps)
    // - `statements` → [`state::allocate_statement_id`] / insert / remove
    //   (dedicated `Mutex`, prepare/execute/close hot path)
    // - `pools` / `pooled_*` → [`state::pools`] (dedicated `Mutex`)
    // - `transactions` → [`state::transactions`] (dedicated `Mutex`)
    // - `xa_*` → [`state::xa`] (dedicated `Mutex`; XA branch lifecycle)
    //
    // Residual fields: `env` (+ optional BCP `connection_strings`).
}

static GLOBAL_STATE: OnceLock<Arc<Mutex<GlobalState>>> = OnceLock::new();
static FFI_PLUGIN_REGISTRY: OnceLock<PluginRegistry> = OnceLock::new();

pub(crate) fn ffi_plugin_registry() -> &'static PluginRegistry {
    FFI_PLUGIN_REGISTRY.get_or_init(PluginRegistry::default)
}

pub(crate) fn get_global_state() -> &'static Arc<Mutex<GlobalState>> {
    GLOBAL_STATE.get_or_init(|| {
        Arc::new(Mutex::new(GlobalState {
            env: None,
            #[cfg(feature = "sqlserver-bcp")]
            connection_strings: HashMap::new(),
        }))
    })
}

pub(crate) fn default_metadata_cache_config() -> (usize, Duration) {
    let size = read_env_usize("ODBC_METADATA_CACHE_SIZE", DEFAULT_METADATA_CACHE_SIZE);
    let ttl_secs = read_env_u64(
        "ODBC_METADATA_CACHE_TTL_SECS",
        DEFAULT_METADATA_CACHE_TTL_SECS,
    );
    (size, Duration::from_secs(ttl_secs))
}

pub(crate) fn read_env_usize(key: &str, default: usize) -> usize {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(default)
}

pub(crate) fn read_env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(default)
}

/// Helper to safely lock global state mutex.
/// Returns None if mutex is poisoned, avoiding panic in FFI.
pub(crate) fn try_lock_global_state() -> Option<std::sync::MutexGuard<'static, GlobalState>> {
    match get_global_state().lock() {
        Ok(guard) => Some(guard),
        Err(poisoned) => {
            #[cfg(test)]
            {
                Some(poisoned.into_inner())
            }
            #[cfg(not(test))]
            {
                let _ = poisoned;
                None
            }
        }
    }
}

/// Set error for a specific connection (thread-safe isolation).
///
/// Sprint 3 + sprint 4 follow-up A2 split: both the per-connection
/// slot and the legacy global error now live in dedicated `RwLock`s
/// outside `GlobalState`. The `state: &mut GlobalState` parameter is
/// kept for call-site compatibility; this function no longer touches
/// `GlobalState` directly. A future cleanup PR can drop the parameter
/// after the surrounding refactor lands.
pub(crate) fn set_connection_error(_state: &mut GlobalState, conn_id: u32, error: String) {
    state::set_connection_error(conn_id, error.clone());
    state::set_legacy_global_error(error);
}

/// Set structured error for a specific connection (thread-safe isolation).
/// See note on [`set_connection_error`] for the storage split.
pub(crate) fn set_connection_structured_error(
    _state: &mut GlobalState,
    conn_id: u32,
    error: crate::error::StructuredError,
) {
    state::set_connection_structured_error(conn_id, error.clone());
    state::set_legacy_global_structured_error(error);
}

/// Set global error (for functions without conn_id like odbc_init).
/// Sprint 4 follow-up A2: legacy global error lives in its own RwLock
/// (see [`state::set_legacy_global_error`]). The `state` parameter is
/// kept only to preserve the call-site shape.
pub(crate) fn set_error(_state: &mut GlobalState, error: String) {
    state::set_legacy_global_error(error);
}

/// Set global structured error (for functions without conn_id).
#[allow(
    dead_code,
    reason = "Legacy FFI error shim; ODBC-ENG-424; remove by 2026-09-30."
)]
pub(crate) fn set_structured_error(_state: &mut GlobalState, error: crate::error::StructuredError) {
    state::set_legacy_global_structured_error(error);
}

/// Get error for a specific connection, or fallback to global error.
///
/// Sprint 3 + sprint 4 follow-up A2: per-connection lookup hits the
/// dedicated `RwLock` in [`state::get_connection_error_message`]; the
/// global fallback hits the dedicated legacy-error `RwLock` via
/// [`state::legacy_global_error_message`]. The `state: &GlobalState`
/// parameter is unused now and stays only to preserve the existing
/// call sites' shape.
pub(crate) fn get_connection_error(_state: &GlobalState, conn_id: Option<u32>) -> String {
    if let Some(id) = conn_id {
        if let Some(msg) = state::get_connection_error_message(id) {
            return msg;
        }
    }
    state::legacy_global_error_message()
}

/// Get structured error for a specific connection.
/// When conn_id is Some(id): returns that connection's error only (no fallback).
/// When conn_id is None: returns the legacy global structured error.
pub(crate) fn get_connection_structured_error(
    _state: &GlobalState,
    conn_id: Option<u32>,
) -> Option<crate::error::StructuredError> {
    if let Some(id) = conn_id {
        // Per-connection isolation: do not fallback to global when asking for a specific conn.
        return state::get_connection_structured_error(id);
    }
    state::legacy_global_structured_error()
}

/// Get global error (legacy function for backward compatibility).
/// Sprint 4 follow-up A2: backed by the dedicated legacy-error
/// `RwLock` in `ffi::state`.
#[allow(
    dead_code,
    reason = "Legacy FFI error shim; ODBC-ENG-424; remove by 2026-09-30."
)]
fn get_error(_state: &GlobalState) -> String {
    state::legacy_global_error_message()
}

pub(crate) struct DisconnectCleanup {
    pub connection: OdbcConnection,
    pub transactions: Vec<Transaction>,
}

pub(crate) enum DisconnectCleanupError {
    BeginInProgress,
    InvalidConnection,
}

pub(crate) fn with_disconnect_cleanup(
    state: &mut GlobalState,
    conn_id: u32,
) -> std::result::Result<DisconnectCleanup, DisconnectCleanupError> {
    #[cfg(feature = "sqlserver-bcp")]
    {
        let _ = state.connection_strings.remove(&conn_id);
    }
    #[cfg(not(feature = "sqlserver-bcp"))]
    {
        let _ = state;
    }

    // Lock order: transactions → connections → statements → streams.
    let result = state::with_transaction_maps_mut(|maps| {
        if maps.begin_in_progress(conn_id) {
            return Err(DisconnectCleanupError::BeginInProgress);
        }
        let Some(connection) = state::remove_connection(conn_id) else {
            return Err(DisconnectCleanupError::InvalidConnection);
        };
        let transactions: Vec<Transaction> = maps
            .take_for_connection(conn_id)
            .into_iter()
            .map(|(_, txn)| txn)
            .collect();
        state::retain_statements_not_for_connection(conn_id);
        state::cancel_streams_for_connection(conn_id);
        Ok(DisconnectCleanup {
            connection,
            transactions,
        })
    });
    result.unwrap_or(Err(DisconnectCleanupError::InvalidConnection))
}

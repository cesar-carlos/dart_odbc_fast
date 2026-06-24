//! Shared FFI globals: re-exports from [`global_state`] and [`runnable`], plus
//! async-request management and parameter-buffer helpers.

use crate::async_bridge;
use crate::engine::ResultEncoding;
pub(crate) use crate::error::{OdbcError, Result};
use std::collections::HashMap;
use std::os::raw::{c_int, c_uint};
use std::sync::atomic::{AtomicBool, Ordering};
pub(crate) use std::sync::Arc;
use std::sync::{Mutex, OnceLock};
use std::time::UNIX_EPOCH;
use tokio::task::JoinHandle;

pub(crate) use super::global_state::*;
pub(crate) use super::runnable::*;

/// Max concurrent async execute requests.
const MAX_ASYNC_REQUESTS: usize = 64;

/// Poll status codes for async execute.
pub(crate) const ASYNC_STATUS_PENDING: c_int = 0;
pub(crate) const ASYNC_STATUS_READY: c_int = 1;
pub(crate) const ASYNC_STATUS_ERROR: c_int = -1;
pub(crate) const ASYNC_STATUS_CANCELLED: c_int = -2;

pub(crate) enum AsyncRequestOutcome {
    Pending,
    Ready(Result<Vec<u8>>),
    Cancelled,
    Consumed,
}

pub(crate) struct AsyncRequestSlot {
    pub(crate) conn_id: u32,
    pub(crate) cancelled: AtomicBool,
    pub(crate) outcome: Mutex<AsyncRequestOutcome>,
    pub(crate) join_handle: Mutex<Option<JoinHandle<()>>>,
}

impl AsyncRequestSlot {
    fn new(conn_id: u32) -> Self {
        Self {
            conn_id,
            cancelled: AtomicBool::new(false),
            outcome: Mutex::new(AsyncRequestOutcome::Pending),
            join_handle: Mutex::new(None),
        }
    }

    fn set_join_handle(&self, handle: JoinHandle<()>) {
        if let Ok(mut h) = self.join_handle.lock() {
            *h = Some(handle);
        }
    }

    fn poll_status(&self) -> c_int {
        let Ok(outcome) = self.outcome.lock() else {
            return ASYNC_STATUS_ERROR;
        };
        match &*outcome {
            AsyncRequestOutcome::Pending => ASYNC_STATUS_PENDING,
            AsyncRequestOutcome::Ready(Ok(_)) => ASYNC_STATUS_READY,
            AsyncRequestOutcome::Ready(Err(_)) => ASYNC_STATUS_ERROR,
            AsyncRequestOutcome::Cancelled => ASYNC_STATUS_CANCELLED,
            AsyncRequestOutcome::Consumed => ASYNC_STATUS_ERROR,
        }
    }
}

pub(crate) struct AsyncRequestManager {
    pub(crate) next_request_id: u32,
    pub(crate) requests: HashMap<u32, Arc<AsyncRequestSlot>>,
}

impl AsyncRequestManager {
    pub(crate) fn new() -> Self {
        Self {
            next_request_id: 1,
            requests: HashMap::new(),
        }
    }

    pub(crate) fn allocate_request_id(&mut self) -> Option<u32> {
        if self.requests.len() >= MAX_ASYNC_REQUESTS {
            return None;
        }

        for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
            let id = self.next_request_id;
            self.next_request_id = self.next_request_id.wrapping_add(1);
            if id != 0 && !self.requests.contains_key(&id) {
                return Some(id);
            }
        }
        None
    }

    pub(crate) fn start_request(
        &mut self,
        conn_id: u32,
        sql: String,
        params: Option<Vec<u8>>,
        result_encoding: u32,
    ) -> Option<u32> {
        let request_id = self.allocate_request_id()?;
        let slot = Arc::new(AsyncRequestSlot::new(conn_id));
        let slot_for_worker = Arc::clone(&slot);

        let handle = match async_bridge::spawn_blocking_task(move || {
            let result = std::panic::catch_unwind(|| {
                run_async_query(conn_id, &sql, params.as_deref(), result_encoding)
            })
            .unwrap_or_else(|_| {
                Err(OdbcError::InternalError(
                    "Async request task panicked".to_string(),
                ))
            });
            let cancelled = slot_for_worker.cancelled.load(Ordering::SeqCst);
            if let Ok(mut outcome) = slot_for_worker.outcome.lock() {
                *outcome = if cancelled {
                    AsyncRequestOutcome::Cancelled
                } else {
                    AsyncRequestOutcome::Ready(result)
                };
            }
        }) {
            Ok(h) => h,
            Err(_) => return None,
        };

        slot.set_join_handle(handle);
        self.requests.insert(request_id, slot);
        Some(request_id)
    }

    pub(crate) fn poll(&self, request_id: u32) -> Option<c_int> {
        self.requests
            .get(&request_id)
            .map(|slot| slot.poll_status())
    }

    pub(crate) fn cancel(&self, request_id: u32) -> bool {
        let Some(slot) = self.requests.get(&request_id) else {
            return false;
        };
        slot.cancelled.store(true, Ordering::SeqCst);
        if let Ok(handle) = slot.join_handle.lock() {
            if let Some(h) = handle.as_ref() {
                h.abort();
            }
        }
        if let Ok(mut outcome) = slot.outcome.lock() {
            if matches!(*outcome, AsyncRequestOutcome::Pending) {
                *outcome = AsyncRequestOutcome::Cancelled;
            }
        }
        true
    }

    pub(crate) fn take_result(&self, request_id: u32) -> Option<(u32, Result<Vec<u8>>)> {
        let slot = self.requests.get(&request_id)?;
        let conn_id = slot.conn_id;
        let Ok(mut outcome) = slot.outcome.lock() else {
            return Some((
                conn_id,
                Err(OdbcError::InternalError(
                    "Async request outcome lock poisoned".to_string(),
                )),
            ));
        };

        let current = std::mem::replace(&mut *outcome, AsyncRequestOutcome::Consumed);
        match current {
            AsyncRequestOutcome::Ready(result) => Some((conn_id, result)),
            AsyncRequestOutcome::Cancelled => Some((
                conn_id,
                Err(OdbcError::InternalError(
                    "Async request cancelled".to_string(),
                )),
            )),
            AsyncRequestOutcome::Pending => {
                *outcome = AsyncRequestOutcome::Pending;
                None
            }
            AsyncRequestOutcome::Consumed => Some((
                conn_id,
                Err(OdbcError::InternalError(
                    "Async request result already consumed".to_string(),
                )),
            )),
        }
    }

    pub(crate) fn restore_result(&self, request_id: u32, result: Result<Vec<u8>>) -> bool {
        let Some(slot) = self.requests.get(&request_id) else {
            return false;
        };
        let Ok(mut outcome) = slot.outcome.lock() else {
            return false;
        };
        *outcome = AsyncRequestOutcome::Ready(result);
        true
    }

    pub(crate) fn free(&mut self, request_id: u32) -> bool {
        let Some(slot) = self.requests.remove(&request_id) else {
            return false;
        };
        if let Ok(mut handle) = slot.join_handle.lock() {
            if let Some(h) = handle.take() {
                h.abort();
            }
        }
        true
    }

    pub(crate) fn free_for_connection(&mut self, conn_id: u32) {
        let request_ids: Vec<u32> = self
            .requests
            .iter()
            .filter_map(|(request_id, slot)| (slot.conn_id == conn_id).then_some(*request_id))
            .collect();
        for request_id in request_ids {
            let _ = self.free(request_id);
        }
    }
}

/// Sprint 3 split: dedicated lock for the async-request subsystem.
/// Lives outside of `GlobalState` so polling, cancelling, and freeing
/// async requests no longer contends with the outer mutex used by the
/// rest of the FFI surface.
static ASYNC_REQUESTS: OnceLock<Mutex<AsyncRequestManager>> = OnceLock::new();

/// Returns the process-wide async-request manager mutex.
///
/// The `OnceLock::get_or_init` call is thread-safe — concurrent first
/// callers race on the init closure and only one runs; the others
/// observe the fully-initialised `Mutex<AsyncRequestManager>`. The
/// inner `Mutex` is freshly constructed inside the closure so the lock
/// is usable the instant `get_or_init` returns, with no separate
/// "ready" handshake required.
fn async_requests() -> &'static Mutex<AsyncRequestManager> {
    ASYNC_REQUESTS.get_or_init(|| Mutex::new(AsyncRequestManager::new()))
}

/// Acquire the async-request manager lock. Returns `None` only when the
/// inner mutex is poisoned (treated by FFI guards as an internal error).
/// First-access thread-safety is documented on [`async_requests`].
pub(crate) fn lock_async_requests() -> Option<std::sync::MutexGuard<'static, AsyncRequestManager>> {
    async_requests().lock().ok()
}

pub(crate) const CANCEL_UNSUPPORTED_NATIVE_CODE: i32 = 5001;

/// Sprint 4.2 helper: route a parameterised FFI call through the
/// per-connection `CachedConnection` cache when the parameter buffer
/// describes a plain legacy `ParamValue` list with no NULLs, falling
/// back to the raw-connection dispatcher otherwise.
///
/// The fallback covers:
///
/// - Any DRT1-directed parameter buffer (`OUT` / `INOUT` slots).
/// - Any legacy list that contains at least one `ParamValue::Null`,
///   because the existing `PreparedNullAware` plan needs descriptor
///   lookups (`stmt.parameter_descriptions()`) that the cached
///   prepared-handle path does not perform.
/// - Buffers that fail to deserialise (validation errors are surfaced
///   via the fallback so the existing error reporting path stays
///   responsible for them).
pub(crate) fn try_cached_legacy_params(
    cached: &mut crate::handles::CachedConnection,
    sql: &str,
    params_slice: &[u8],
) -> Result<Vec<u8>> {
    cached.try_execute_param_buffer_with_encoding(sql, params_slice, ResultEncoding::RowMajor)
}

/// Cached counterpart of [`try_cached_legacy_params`] that honours the
/// requested wire encoding while reusing prepared handles when eligible.
pub(crate) fn try_cached_params_with_encoding(
    cached: &mut crate::handles::CachedConnection,
    sql: &str,
    params_slice: &[u8],
    encoding: ResultEncoding,
) -> Result<Vec<u8>> {
    cached.try_execute_param_buffer_with_encoding(sql, params_slice, encoding)
}

/// Build a cache key of the form `"<conn_id>:<table>"` in a single
/// allocation. Replaces the previous `conn_id.to_string()` + `String`
/// concatenation that did two allocations per catalog lookup (sprint 1
/// follow-up B8).
pub(crate) fn build_catalog_cache_key(conn_id: u32, table: &str) -> String {
    use std::fmt::Write;
    // `u32::MAX` formats to 10 chars; the `+ 1` accounts for the colon
    // separator, and the `table.len()` reservation matches the worst
    // case so `write!` never needs to realloc.
    let mut key = String::with_capacity(10 + 1 + table.len());
    // `write!` on `String` is infallible (`fmt::Error` is impossible for
    // an in-memory writer); the `expect` documents that invariant.
    write!(&mut key, "{}:{}", conn_id, table).expect("formatting into String never fails");
    key
}

pub(crate) fn validate_param_buffer_shape(
    params_buffer: *const u8,
    params_len: c_uint,
) -> std::result::Result<(), &'static str> {
    if params_buffer.is_null() {
        if params_len > 0 {
            Err("params_buffer is null but params_len is greater than zero")
        } else {
            Ok(())
        }
    } else {
        Ok(())
    }
}

/// Borrows an optional FFI parameter buffer only for the callback duration.
///
/// # Safety
///
/// When `params_buffer` is non-null and `params_len > 0`, the caller must
/// guarantee the memory is valid for reads of `params_len` bytes for the full
/// duration of `callback`. The callback must not store the borrowed slice.
pub(crate) unsafe fn with_optional_param_buffer<R>(
    params_buffer: *const u8,
    params_len: c_uint,
    callback: impl FnOnce(&[u8]) -> R,
) -> std::result::Result<R, &'static str> {
    validate_param_buffer_shape(params_buffer, params_len)?;
    if params_buffer.is_null() || params_len == 0 {
        return Ok(callback(&[]));
    }

    // SAFETY: guaranteed by the caller contract above; the slice is scoped to
    // this function and cannot outlive the callback invocation.
    let params = unsafe { std::slice::from_raw_parts(params_buffer, params_len as usize) };
    Ok(callback(params))
}

/// Copies an optional FFI parameter buffer for work that outlives the FFI call.
///
/// # Safety
///
/// Same caller obligations as [`with_optional_param_buffer`].
pub(crate) unsafe fn read_param_buffer_owned(
    params_buffer: *const u8,
    params_len: c_uint,
) -> std::result::Result<Vec<u8>, &'static str> {
    // SAFETY: forwarded from this function's safety contract. The callback
    // copies immediately, so no borrowed FFI pointer escapes.
    unsafe { with_optional_param_buffer(params_buffer, params_len, |params| params.to_vec()) }
}

pub(crate) fn set_invalid_param_buffer_error(state: &mut GlobalState, conn_id: u32, message: &str) {
    set_connection_error(state, conn_id, message.to_string());
}

pub(crate) fn serialize_audit_events(
    events: Vec<crate::security::audit::AuditEvent>,
) -> Result<Vec<u8>> {
    let serialized_events: Vec<serde_json::Value> = events
        .into_iter()
        .map(|event| {
            let timestamp_ms = event
                .timestamp
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_millis() as u64)
                .unwrap_or(0);

            serde_json::json!({
                "timestamp_ms": timestamp_ms,
                "event_type": event.event_type,
                "connection_id": event.connection_id,
                "query": event.query,
                "metadata": event.metadata,
            })
        })
        .collect();

    serde_json::to_vec(&serialized_events).map_err(|error| {
        OdbcError::InternalError(format!("Failed to serialize audit events: {}", error))
    })
}

pub(crate) fn serialize_audit_status(
    audit_logger: &crate::security::AuditLogger,
) -> Result<Vec<u8>> {
    let payload = serde_json::json!({
        "enabled": audit_logger.is_enabled(),
        "event_count": audit_logger.event_count(),
    });

    serde_json::to_vec(&payload).map_err(|error| {
        OdbcError::InternalError(format!("Failed to serialize audit status: {}", error))
    })
}

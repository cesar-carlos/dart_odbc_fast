//! Pending result buffers for FFI `-2` (buffer too small) retries.
//!
//! When an exec API produces a payload larger than the caller's output
//! buffer it returns `-2` and stashes the bytes here. The next matching
//! call with a large enough buffer consumes the stash instead of
//! re-executing SQL (critical for side-effecting statements).
//!
//! Lock ordering: acquire after statements / streams when both are needed;
//! never hold this lock while acquiring `GLOBAL_STATE`.

use super::super::global_state::{set_out_written_needed, FFI_ERR_BUFFER_TOO_SMALL, FFI_OK};
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::os::raw::c_int;
use std::os::raw::c_uint;
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

const PENDING_RESULT_TTL: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum PendingResultKey {
    ExecQuery {
        conn_id: u32,
        sql_hash: u64,
    },
    ExecQueryParams {
        conn_id: u32,
        sql_hash: u64,
        params_hash: u64,
    },
    ExecQueryMulti {
        conn_id: u32,
        sql_hash: u64,
    },
    Execute {
        stmt_id: u32,
        params_hash: u64,
        timeout_override_ms: u32,
        fetch_size: u32,
    },
}

struct PendingResultBuffer {
    data: Vec<u8>,
    created_at: Instant,
}

struct PendingMaps {
    buffers: HashMap<PendingResultKey, PendingResultBuffer>,
}

fn pending_maps() -> &'static Mutex<PendingMaps> {
    static MAPS: OnceLock<Mutex<PendingMaps>> = OnceLock::new();
    MAPS.get_or_init(|| {
        Mutex::new(PendingMaps {
            buffers: HashMap::new(),
        })
    })
}

fn try_lock_pending_maps() -> Option<MutexGuard<'static, PendingMaps>> {
    match pending_maps().lock() {
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

pub(crate) fn hash_bytes(bytes: &[u8]) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut hasher);
    hasher.finish()
}

/// Try to deliver a previously stashed payload for `key`.
///
/// Returns:
/// - `Some(0)` when the pending payload was copied into `out_buffer`
/// - `Some(-2)` when a pending payload exists but the buffer is still too small
/// - `None` when there is no usable pending entry (caller should execute)
pub(crate) fn try_write_pending_result(
    key: &PendingResultKey,
    out_buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> Option<c_int> {
    if out_buffer.is_null() || out_written.is_null() {
        return Some(-1);
    }
    let mut maps = try_lock_pending_maps()?;
    let entry = maps.buffers.remove(key)?;
    if entry.created_at.elapsed() > PENDING_RESULT_TTL {
        return None;
    }

    if entry.data.len() > buffer_len as usize {
        let needed = entry.data.len();
        maps.buffers.insert(key.clone(), entry);
        set_out_written_needed(out_written, needed);
        return Some(FFI_ERR_BUFFER_TOO_SMALL);
    }

    // SAFETY: null pointers rejected above; `entry.data.len() <= buffer_len`.
    unsafe {
        std::ptr::copy_nonoverlapping(entry.data.as_ptr(), out_buffer, entry.data.len());
        *out_written = entry.data.len() as c_uint;
    }
    Some(FFI_OK)
}

pub(crate) fn stash_pending_result(key: PendingResultKey, data: Vec<u8>) {
    if let Some(mut maps) = try_lock_pending_maps() {
        maps.buffers.insert(
            key,
            PendingResultBuffer {
                data,
                created_at: Instant::now(),
            },
        );
    }
}

/// Drop pending exec payloads for a connection (disconnect / pool close).
pub(crate) fn clear_pending_for_connection(conn_id: u32) {
    if let Some(mut maps) = try_lock_pending_maps() {
        maps.buffers.retain(|key, _| match key {
            PendingResultKey::ExecQuery {
                conn_id: key_conn, ..
            }
            | PendingResultKey::ExecQueryParams {
                conn_id: key_conn, ..
            }
            | PendingResultKey::ExecQueryMulti {
                conn_id: key_conn, ..
            } => *key_conn != conn_id,
            PendingResultKey::Execute { .. } => true,
        });
    }
}

/// Drop pending prepared-execute payloads for one statement.
pub(crate) fn clear_pending_for_statement(stmt_id: u32) {
    if let Some(mut maps) = try_lock_pending_maps() {
        maps.buffers.retain(|key, _| match key {
            PendingResultKey::Execute {
                stmt_id: key_stmt, ..
            } => *key_stmt != stmt_id,
            _ => true,
        });
    }
}

/// Drop every prepared-execute pending entry (clear-all statements).
pub(crate) fn clear_pending_execute_entries() {
    if let Some(mut maps) = try_lock_pending_maps() {
        maps.buffers
            .retain(|key, _| !matches!(key, PendingResultKey::Execute { .. }));
    }
}

/// When `status` is buffer-too-small, stash `data` under `key`.
pub(crate) fn stash_if_buffer_too_small(
    status: c_int,
    key: PendingResultKey,
    data: Vec<u8>,
) -> c_int {
    if status == FFI_ERR_BUFFER_TOO_SMALL {
        stash_pending_result(key, data);
    }
    status
}

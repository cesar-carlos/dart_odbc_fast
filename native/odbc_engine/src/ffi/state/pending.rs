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
    #[cfg(test)]
    drop_observer: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
}

#[cfg(test)]
impl Drop for PendingResultBuffer {
    fn drop(&mut self) {
        if let Some(observer) = &self.drop_observer {
            observer.store(
                pending_maps().try_lock().is_ok(),
                std::sync::atomic::Ordering::SeqCst,
            );
        }
    }
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
        drop(maps);
        return None;
    }

    if entry.data.len() > buffer_len as usize {
        let needed = entry.data.len();
        maps.buffers.insert(key.clone(), entry);
        set_out_written_needed(out_written, needed);
        return Some(FFI_ERR_BUFFER_TOO_SMALL);
    }
    drop(maps);

    // SAFETY: null pointers rejected above; `entry.data.len() <= buffer_len`.
    unsafe {
        std::ptr::copy_nonoverlapping(entry.data.as_ptr(), out_buffer, entry.data.len());
        *out_written = entry.data.len() as c_uint;
    }
    Some(FFI_OK)
}

pub(crate) fn stash_pending_result(key: PendingResultKey, data: Vec<u8>) {
    if let Some(mut maps) = try_lock_pending_maps() {
        let replaced = maps.buffers.insert(
            key,
            PendingResultBuffer {
                data,
                created_at: Instant::now(),
                #[cfg(test)]
                drop_observer: None,
            },
        );
        drop(maps);
        drop(replaced);
    }
}

fn clear_pending_matching(mut should_remove: impl FnMut(&PendingResultKey) -> bool) {
    if let Some(mut maps) = try_lock_pending_maps() {
        let keys: Vec<_> = maps
            .buffers
            .keys()
            .filter(|key| should_remove(key))
            .cloned()
            .collect();
        let removed: Vec<_> = keys
            .into_iter()
            .filter_map(|key| maps.buffers.remove(&key))
            .collect();
        drop(maps);
        drop(removed);
    }
}

/// Drop pending exec payloads for a connection (disconnect / pool close).
pub(crate) fn clear_pending_for_connection(conn_id: u32) {
    clear_pending_matching(|key| match key {
        PendingResultKey::ExecQuery {
            conn_id: key_conn, ..
        }
        | PendingResultKey::ExecQueryParams {
            conn_id: key_conn, ..
        }
        | PendingResultKey::ExecQueryMulti {
            conn_id: key_conn, ..
        } => *key_conn == conn_id,
        PendingResultKey::Execute { .. } => false,
    });
}

/// Drop pending prepared-execute payloads for one statement.
pub(crate) fn clear_pending_for_statement(stmt_id: u32) {
    clear_pending_matching(|key| match key {
        PendingResultKey::Execute {
            stmt_id: key_stmt, ..
        } => *key_stmt == stmt_id,
        _ => false,
    });
}

/// Drop every prepared-execute pending entry (clear-all statements).
pub(crate) fn clear_pending_execute_entries() {
    clear_pending_matching(|key| matches!(key, PendingResultKey::Execute { .. }));
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    #[test]
    fn expired_replaced_and_cleared_payloads_drop_after_unlock() {
        let cases = [0u32, 1, 2];
        for case in cases {
            let key = PendingResultKey::ExecQuery {
                conn_id: u32::MAX - 20 - case,
                sql_hash: 0xA11CE,
            };
            let observed = Arc::new(AtomicBool::new(false));
            let created_at = if case == 0 {
                Instant::now() - PENDING_RESULT_TTL - Duration::from_millis(1)
            } else {
                Instant::now()
            };
            try_lock_pending_maps()
                .expect("pending lock")
                .buffers
                .insert(
                    key.clone(),
                    PendingResultBuffer {
                        data: vec![7; 4096],
                        created_at,
                        drop_observer: Some(Arc::clone(&observed)),
                    },
                );
            match case {
                0 => {
                    let mut output = vec![0u8; 4096];
                    let mut written = 0;
                    assert_eq!(
                        try_write_pending_result(&key, output.as_mut_ptr(), 4096, &mut written),
                        None
                    );
                }
                1 => stash_pending_result(key.clone(), vec![1; 32]),
                _ => clear_pending_for_connection(u32::MAX - 20 - case),
            }
            assert!(
                observed.load(Ordering::SeqCst),
                "case {case} dropped under lock"
            );
            clear_pending_for_connection(u32::MAX - 20 - case);
        }
        for clear_all in [false, true] {
            let stmt_id = if clear_all {
                u32::MAX - 31
            } else {
                u32::MAX - 30
            };
            let key = PendingResultKey::Execute {
                stmt_id,
                params_hash: 0xA11CE,
                timeout_override_ms: 0,
                fetch_size: 100,
            };
            let observed = Arc::new(AtomicBool::new(false));
            try_lock_pending_maps()
                .expect("pending lock")
                .buffers
                .insert(
                    key,
                    PendingResultBuffer {
                        data: vec![8; 4096],
                        created_at: Instant::now(),
                        drop_observer: Some(Arc::clone(&observed)),
                    },
                );
            if clear_all {
                clear_pending_execute_entries();
            } else {
                clear_pending_for_statement(stmt_id);
            }
            assert!(
                observed.load(Ordering::SeqCst),
                "statement payload dropped under lock"
            );
        }
    }

    #[test]
    fn repeated_small_retries_preserve_entry_and_timestamp() {
        let key = PendingResultKey::ExecQuery {
            conn_id: u32::MAX,
            sql_hash: 0xA11CE,
        };
        stash_pending_result(key.clone(), vec![7; 4096]);
        let created_at = try_lock_pending_maps()
            .expect("pending lock")
            .buffers
            .get(&key)
            .expect("entry")
            .created_at;
        for _ in 0..3 {
            let mut output = [0u8; 8];
            let mut written = 0;
            assert_eq!(
                try_write_pending_result(&key, output.as_mut_ptr(), 8, &mut written),
                Some(FFI_ERR_BUFFER_TOO_SMALL)
            );
            assert_eq!(written, 4096);
            let maps = try_lock_pending_maps().expect("pending lock");
            assert_eq!(
                maps.buffers.get(&key).expect("entry").created_at,
                created_at
            );
        }
        let mut output = vec![0; 4096];
        let mut written = 0;
        assert_eq!(
            try_write_pending_result(&key, output.as_mut_ptr(), 4096, &mut written),
            Some(FFI_OK)
        );
        assert_eq!(written, 4096);
        assert!(output.iter().all(|byte| *byte == 7));
        assert!(!try_lock_pending_maps()
            .expect("pending lock")
            .buffers
            .contains_key(&key));
    }

    #[test]
    fn independent_pending_copies_can_run_concurrently() {
        std::thread::scope(|scope| {
            let workers: Vec<_> = (0..8u32)
                .map(|id| {
                    scope.spawn(move || {
                        let key = PendingResultKey::ExecQuery {
                            conn_id: u32::MAX - id,
                            sql_hash: 0xC0FFEE,
                        };
                        stash_pending_result(key.clone(), vec![id as u8; 64 * 1024]);
                        let mut output = vec![0; 64 * 1024];
                        let mut written = 0;
                        assert_eq!(
                            try_write_pending_result(
                                &key,
                                output.as_mut_ptr(),
                                output.len() as u32,
                                &mut written,
                            ),
                            Some(FFI_OK)
                        );
                        assert_eq!(written as usize, output.len());
                        assert!(output.iter().all(|byte| *byte == id as u8));
                    })
                })
                .collect();
            for worker in workers {
                worker.join().expect("pending worker");
            }
        });
    }
}

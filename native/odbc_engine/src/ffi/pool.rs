// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use super::global::*;
use super::prelude::*;
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

fn pool_create_inner(
    conn_str: &str,
    max_size: c_uint,
    options: crate::pool::PoolOptions,
) -> c_uint {
    match ConnectionPool::new_with_options(conn_str, max_size, options) {
        Ok(pool) => {
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            let pool_id = {
                let mut id = 0u32;
                for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
                    let candidate = state.next_pool_id;
                    state.next_pool_id = state.next_pool_id.wrapping_add(1);
                    if candidate != 0 && !state.pools.contains_key(&candidate) {
                        id = candidate;
                        break;
                    }
                }
                if id == 0 {
                    set_error(&mut state, "Failed to allocate pool ID".to_string());
                    return 0;
                }
                id
            };
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
    crate::ffi_guard_id!(c_uint, {
        // C3 fix: do NOT hold the global state lock while calling `r2d2::Pool::get()`,
        // which can block for the configured pool timeout (~30s). We clone the
        // Arc<ConnectionPool>, release the lock, perform the blocking acquire,
        // then re-acquire the lock briefly to install the connection.
        let pool_arc = {
            let Some(state) = try_lock_global_state() else {
                return 0;
            };
            match state.pools.get(&pool_id) {
                Some(p) => Arc::clone(p),
                None => {
                    drop(state);
                    if let Some(mut state) = try_lock_global_state() {
                        set_error(&mut state, format!("Invalid pool ID: {}", pool_id));
                    }
                    return 0;
                }
            }
        };

        let pooled_wrapper = pool_arc.get();

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };

        match pooled_wrapper {
            Ok(pooled_wrapper) => {
                // Guard against the pool being closed between the checkout and
                // the state re-lock. The connection is physically valid (the
                // local `pool_arc` keeps r2d2 alive) but its pool_id no longer
                // exists in state.pools. Register it so the caller can use and
                // release it normally; the orphaned pooled_free_ids entry will
                // be ignored on future checkouts since the pool is gone.
                if !state.pools.contains_key(&pool_id) {
                    log::warn!(
                        "odbc_pool_get_connection: pool {} was closed while connection was \
                         being checked out; connection is usable but pool is orphaned",
                        pool_id
                    );
                }
                let conn_id = state
                    .pooled_free_ids
                    .get_mut(&pool_id)
                    .and_then(|ids| ids.pop())
                    .or_else(|| {
                        let mut id = None;
                        for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
                            let candidate = state.next_pooled_conn_id;
                            state.next_pooled_conn_id = state.next_pooled_conn_id.wrapping_add(1);
                            if candidate != 0 && !state.pooled_connections.contains_key(&candidate)
                            {
                                id = Some(candidate);
                                break;
                            }
                        }
                        id
                    });

                let Some(conn_id) = conn_id else {
                    set_error(
                        &mut state,
                        "Failed to allocate pooled connection ID".to_string(),
                    );
                    return 0;
                };

                state.pooled_connections.insert(
                    conn_id,
                    PooledConnectionState {
                        pool_id,
                        pooled: Arc::new(Mutex::new(pooled_wrapper)),
                    },
                );
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
    })
}

/// Release pooled connection back to pool.
/// RAII: rolls back any active transaction and restores autocommit before return.
/// Closes all prepared statements for this connection before release.
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_pool_release_connection(connection_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };

        if !state.pooled_connections.contains_key(&connection_id) {
            set_error(
                &mut state,
                format!("Invalid pooled connection ID: {}", connection_id),
            );
            return 1;
        }
        if state
            .transaction_begins_in_progress
            .contains(&connection_id)
        {
            set_connection_error(
                &mut state,
                connection_id,
                "Cannot release pooled connection while transaction begin is in progress"
                    .to_string(),
            );
            return 1;
        }
        if state
            .pooled_connection_busy_counts
            .get(&connection_id)
            .copied()
            .unwrap_or(0)
            > 0
        {
            set_connection_error(
                &mut state,
                connection_id,
                "Cannot release pooled connection while it is executing".to_string(),
            );
            return 1;
        }

        let entry = match state.pooled_connections.remove(&connection_id) {
            Some(e) => e,
            None => {
                set_error(
                    &mut state,
                    format!(
                        "pooled connection {} disappeared before removal",
                        connection_id
                    ),
                );
                return -1;
            }
        };
        let transactions = take_transactions_for_connection(&mut state, connection_id);
        state
            .statements
            .retain(|_, stmt| stmt.conn_id() != connection_id);
        drop(state);

        rollback_transactions_best_effort(transactions);
        if let Ok(mut pooled) = entry.pooled.lock() {
            let conn = pooled.get_connection_mut();
            let _ = conn.rollback();
            let _ = conn.set_autocommit(true);
        } else {
            log::warn!("Failed to lock pooled connection {connection_id} during release cleanup");
        }

        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        state
            .pooled_free_ids
            .entry(entry.pool_id)
            .or_default()
            .push(connection_id);
        0
    })
}

/// Health check for pool
/// pool_id: pool ID
/// Returns: 1 if healthy, 0 if unhealthy
#[no_mangle]
pub extern "C" fn odbc_pool_health_check(pool_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(state) = try_lock_global_state() else {
            return 0;
        };

        let Some(pool) = state.pools.get(&pool_id).cloned() else {
            return 0;
        };
        drop(state);

        if pool.health_check() {
            1
        } else {
            0
        }
    })
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
    crate::ffi_guard_int!({
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
            .filter(|entry| entry.pool_id == pool_id)
            .count() as u32;
        let idle = max_size.saturating_sub(active);

        // SAFETY: `out_size` and `out_idle` are non-null (checked above); each
        // write covers a single `c_uint`-sized slot as guaranteed by the caller.
        unsafe {
            *out_size = max_size;
            *out_idle = idle;
        }

        0
    })
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
    crate::ffi_guard_int!({
        if buffer.is_null() || out_written.is_null() {
            return -1;
        }

        let Some(state) = try_lock_global_state() else {
            return -1;
        };

        let pool = match state.pools.get(&pool_id) {
            Some(p) => p,
            None => {
                set_out_written_zero(out_written);
                return -1;
            }
        };

        let pool_state = pool.state();
        let total = pool_state.size;
        let idle = pool_state.idle;
        let active = total.saturating_sub(idle);
        let max_size = pool.max_size();

        let json = format!(
            r#"{{"total_connections":{},"idle_connections":{},"active_connections":{},"max_size":{},"wait_count":0,"wait_time_ms":0,"max_wait_time_ms":0,"avg_wait_time_ms":0}}"#,
            total, idle, active, max_size
        );

        let bytes = json.as_bytes();
        let needed = bytes.len() + 1;

        if (buffer_len as usize) < needed {
            set_out_written_needed(out_written, needed);
            return -2;
        }

        // SAFETY: `buffer` and `out_written` are non-null (checked above);
        // `bytes.len() + 1 <= buffer_len` (checked above); `buffer.add(bytes.len())`
        // points to the null-terminator slot which is within the allocation.
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, bytes.len());
            *buffer.add(bytes.len()) = 0;
            *out_written = bytes.len() as c_uint;
        }

        0
    })
}

/// Resize pool by recreating it with new max_size.
///
/// All connections must be released before resize. Returns -1 if pool has
/// checked-out connections or on error. r2d2 does not support in-place resize;
/// the pool is recreated with the same connection string.
#[no_mangle]
pub extern "C" fn odbc_pool_set_size(pool_id: c_uint, new_max_size: c_uint) -> c_int {
    crate::ffi_guard_int!({
        if new_max_size == 0 {
            return -1;
        }

        let pool = {
            let Some(mut state) = try_lock_global_state() else {
                return -1;
            };
            let pool = match state.pools.get(&pool_id) {
                Some(p) => p,
                None => {
                    set_error(&mut state, format!("Invalid pool ID: {}", pool_id));
                    return -1;
                }
            };
            let has_checked_out = state
                .pooled_connections
                .values()
                .any(|entry| entry.pool_id == pool_id);
            if has_checked_out {
                set_error(
                    &mut state,
                    "Cannot resize pool while connections are checked out".to_string(),
                );
                return -1;
            }
            if state.pooled_busy_counts.get(&pool_id).copied().unwrap_or(0) > 0 {
                set_error(
                    &mut state,
                    "Cannot resize pool while connections are executing".to_string(),
                );
                return -1;
            }
            if pool_has_begin_in_progress(&state, pool_id) {
                set_error(
                    &mut state,
                    "Cannot resize pool while transaction begin is in progress".to_string(),
                );
                return -1;
            }
            Arc::clone(pool)
        };

        let pool = match pool.recreate_with_max_size(new_max_size) {
            Ok(pool) => pool,
            Err(e) => {
                let Some(mut state) = try_lock_global_state() else {
                    return -1;
                };
                set_error(&mut state, format!("odbc_pool_set_size failed: {}", e));
                return -1;
            }
        };

        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        if state
            .pooled_connections
            .values()
            .any(|entry| entry.pool_id == pool_id)
            || state.pooled_busy_counts.get(&pool_id).copied().unwrap_or(0) > 0
        {
            set_error(
                &mut state,
                "Cannot resize pool while connections are checked out or executing".to_string(),
            );
            return -1;
        }
        if pool_has_begin_in_progress(&state, pool_id) {
            set_error(
                &mut state,
                "Cannot resize pool while transaction begin is in progress".to_string(),
            );
            return -1;
        }
        if !state.pools.contains_key(&pool_id) {
            // Pool was closed or invalidated between the two lock acquisitions.
            // The newly-recreated pool object is discarded here; the resize is
            // effectively a no-op because the pool no longer exists.
            set_error(
                &mut state,
                format!(
                    "Pool {} was closed while resize was in progress; resize aborted",
                    pool_id
                ),
            );
            return -1;
        }
        state.pools.insert(pool_id, Arc::new(pool));
        0
    })
}

/// Close and remove pool.
/// RAII: rolls back and restores autocommit on checked-out connections before close.
/// Releases all checked-out connections and closes their statements.
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_pool_close(pool_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };

        if !state.pools.contains_key(&pool_id) {
            set_error(&mut state, format!("Invalid pool ID: {}", pool_id));
            return 1;
        }
        if state.pooled_busy_counts.get(&pool_id).copied().unwrap_or(0) > 0 {
            set_error(
                &mut state,
                "Cannot close pool while connections are executing".to_string(),
            );
            return 1;
        }
        if pool_has_begin_in_progress(&state, pool_id) {
            set_error(
                &mut state,
                "Cannot close pool while transaction begin is in progress".to_string(),
            );
            return 1;
        }

        // Prevent new checkouts while keeping the pool Arc alive locally until
        // checked-out wrappers are rolled back, restored and dropped.
        // r2d2 returns a `PooledConnection` that releases back to the pool on
        // Drop; holding this Arc preserves pool internals until wrappers drop.
        let pool = match state.pools.remove(&pool_id) {
            Some(p) => p,
            None => {
                set_error(
                    &mut state,
                    format!("pool {} disappeared before removal", pool_id),
                );
                return -1;
            }
        };
        let conn_ids: Vec<u32> = state
            .pooled_connections
            .iter()
            .filter(|(_, entry)| entry.pool_id == pool_id)
            .map(|(cid, _)| *cid)
            .collect();
        let mut checked_out = Vec::with_capacity(conn_ids.len());
        let mut transactions = Vec::new();
        for cid in conn_ids {
            transactions.extend(take_transactions_for_connection(&mut state, cid));
            state.statements.retain(|_, stmt| stmt.conn_id() != cid);
            if let Some(entry) = state.pooled_connections.remove(&cid) {
                checked_out.push(entry.pooled);
            }
        }
        state.pooled_free_ids.remove(&pool_id);
        drop(state);

        rollback_transactions_best_effort(transactions);
        for pooled in checked_out {
            if let Ok(mut pooled) = pooled.lock() {
                let conn = pooled.get_connection_mut();
                let _ = conn.rollback();
                let _ = conn.set_autocommit(true);
            } else {
                log::warn!("Failed to lock pooled connection during pool close cleanup");
            }
            // `pooled` is dropped here, releasing the connection back to the pool.
        }
        drop(pool);
        0
    })
}

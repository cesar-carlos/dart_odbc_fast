use std::sync::Arc;

use super::super::global::*;
use super::super::prelude::*;

pub(super) fn pool_health_check(pool_id: c_uint) -> c_int {
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
}

pub(super) fn pool_get_state(
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
}

pub(super) fn pool_get_state_json(
    pool_id: c_uint,
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
}

pub(super) fn pool_set_size(pool_id: c_uint, new_max_size: c_uint) -> c_int {
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
}

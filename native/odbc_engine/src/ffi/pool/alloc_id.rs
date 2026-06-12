use std::sync::Arc;

use super::super::global::*;
use super::super::prelude::*;

pub(super) fn pool_create_inner(
    conn_str: &str,
    max_size: c_uint,
    options: crate::pool::PoolOptions,
) -> c_uint {
    match ConnectionPool::new_with_options(conn_str, max_size, options) {
        Ok(pool) => {
            let Some(mut state) = try_lock_global_state() else {
                return 0;
            };
            let Some(pool_id) = allocate_pool_id(&mut state) else {
                set_error(&mut state, "Failed to allocate pool ID".to_string());
                return 0;
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

pub(super) fn allocate_pool_id(state: &mut GlobalState) -> Option<u32> {
    for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
        let candidate = state.next_pool_id;
        state.next_pool_id = state.next_pool_id.wrapping_add(1);
        if candidate != 0 && !state.pools.contains_key(&candidate) {
            return Some(candidate);
        }
    }
    None
}

pub(super) fn allocate_pooled_connection_id(state: &mut GlobalState, pool_id: u32) -> Option<u32> {
    state
        .pooled_free_ids
        .get_mut(&pool_id)
        .and_then(|ids| ids.pop())
        .or_else(|| {
            for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
                let candidate = state.next_pooled_conn_id;
                state.next_pooled_conn_id = state.next_pooled_conn_id.wrapping_add(1);
                if candidate != 0 && !state.pooled_connections.contains_key(&candidate) {
                    return Some(candidate);
                }
            }
            None
        })
}

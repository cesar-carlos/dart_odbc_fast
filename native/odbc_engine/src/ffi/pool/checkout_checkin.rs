use std::sync::Arc;

use super::super::global::*;
use super::super::prelude::*;
use super::alloc_id::allocate_pooled_connection_id;

pub(super) fn checkout_pooled_connection(pool_id: c_uint) -> c_uint {
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
            let Some(conn_id) = allocate_pooled_connection_id(&mut state, pool_id) else {
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
}

pub(super) fn checkin_pooled_connection(connection_id: c_uint) -> c_int {
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
            "Cannot release pooled connection while transaction begin is in progress".to_string(),
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
        let _ = pooled.cached_mut().pool_session_reset();
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
}

pub(super) fn close_pool(pool_id: c_uint) -> c_int {
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
            let _ = pooled.cached_mut().pool_session_reset();
        } else {
            log::warn!("Failed to lock pooled connection during pool close cleanup");
        }
        // `pooled` is dropped here, releasing the connection back to the pool.
    }
    drop(pool);
    0
}

use std::sync::Arc;

use super::super::global::*;
use super::super::prelude::*;
use crate::ffi::state;

/// Recycles a pooled connection ID when pool-maps re-lock fails after checkin cleanup.
struct PooledConnIdRecycleGuard {
    pool_id: u32,
    connection_id: u32,
    armed: bool,
}

impl PooledConnIdRecycleGuard {
    fn new(pool_id: u32, connection_id: u32) -> Self {
        Self {
            pool_id,
            connection_id,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for PooledConnIdRecycleGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        state::recycle_pooled_connection_id(self.pool_id, self.connection_id);
    }
}

pub(super) fn checkout_pooled_connection(pool_id: c_uint) -> c_uint {
    // C3 fix: do NOT hold the pool maps lock while calling `r2d2::Pool::get()`,
    // which can block for the configured pool timeout (~30s). We clone the
    // Arc<ConnectionPool>, release the lock, perform the blocking acquire,
    // then re-acquire the lock briefly to install the connection.
    let Some(pool_arc) = state::get_pool(pool_id) else {
        if let Some(mut gs) = try_lock_global_state() {
            set_error(&mut gs, format!("Invalid pool ID: {}", pool_id));
        }
        return 0;
    };

    let pooled_wrapper = pool_arc.get();

    match pooled_wrapper {
        Ok(pooled_wrapper) => {
            // Guard against the pool being closed between the checkout and
            // the state re-lock. The connection is physically valid (the
            // local `pool_arc` keeps r2d2 alive) but its pool_id may no
            // longer exist. Register it so the caller can use and release
            // it normally; the orphaned free-id entry will be ignored on
            // future checkouts since the pool is gone.
            let install = state::with_pool_maps_mut(|maps| {
                if !maps.contains_pool(pool_id) {
                    log::warn!(
                        "odbc_pool_get_connection: pool {} was closed while connection was \
                         being checked out; connection is usable but pool is orphaned",
                        pool_id
                    );
                }
                let Some(conn_id) = maps.allocate_pooled_connection_id(pool_id) else {
                    return Err("Failed to allocate pooled connection ID".to_string());
                };
                maps.insert_pooled_connection(
                    conn_id,
                    pool_id,
                    Arc::new(Mutex::new(pooled_wrapper)),
                );
                Ok(conn_id)
            });
            match install {
                Some(Ok(conn_id)) => conn_id,
                Some(Err(msg)) => {
                    if let Some(mut gs) = try_lock_global_state() {
                        set_error(&mut gs, msg);
                    }
                    0
                }
                None => 0,
            }
        }
        Err(e) => {
            if let Some(mut gs) = try_lock_global_state() {
                set_error(
                    &mut gs,
                    format!("Failed to get connection from pool: {}", e),
                );
            }
            0
        }
    }
}

pub(super) fn checkin_pooled_connection(connection_id: c_uint) -> c_int {
    // Lock order: transactions → pools.
    let remove_result = state::with_transaction_maps_mut(|txn_maps| {
        if txn_maps.begin_in_progress(connection_id) {
            return Err("begin");
        }
        let entry = state::with_pool_maps_mut(|maps| {
            if !maps.contains_pooled_connection(connection_id) {
                return Err("invalid");
            }
            if maps.pooled_connection_busy_count(connection_id) > 0 {
                return Err("busy");
            }
            match maps.remove_pooled_connection(connection_id) {
                Some(entry) => Ok(entry),
                None => Err("gone"),
            }
        });
        match entry {
            Some(Ok(entry)) => {
                let transactions = txn_maps.take_for_connection(connection_id);
                Ok((entry, transactions))
            }
            Some(Err(code)) => Err(code),
            None => Err("gone"),
        }
    });

    let (entry, transactions) = match remove_result {
        Some(Ok(v)) => v,
        Some(Err("begin")) => {
            if let Some(mut gs) = try_lock_global_state() {
                set_connection_error(
                    &mut gs,
                    connection_id,
                    "Cannot release pooled connection while transaction begin is in progress"
                        .to_string(),
                );
            }
            return 1;
        }
        Some(Err("invalid")) => {
            if let Some(mut gs) = try_lock_global_state() {
                set_error(
                    &mut gs,
                    format!("Invalid pooled connection ID: {}", connection_id),
                );
            }
            return 1;
        }
        Some(Err("busy")) => {
            if let Some(mut gs) = try_lock_global_state() {
                set_connection_error(
                    &mut gs,
                    connection_id,
                    "Cannot release pooled connection while it is executing".to_string(),
                );
            }
            return 1;
        }
        Some(Err(_)) | None => {
            if let Some(mut gs) = try_lock_global_state() {
                set_error(
                    &mut gs,
                    format!(
                        "pooled connection {} disappeared before removal",
                        connection_id
                    ),
                );
            }
            return -1;
        }
    };

    let pool_id = entry.pool_id;
    let mut id_recycle_guard = PooledConnIdRecycleGuard::new(pool_id, connection_id);
    if let Some(cache) = state::metadata_cache_read() {
        cache.remove_payloads_with_conn_prefix(connection_id);
    }
    state::retain_statements_not_for_connection(connection_id);

    state::rollback_transactions_best_effort(transactions);
    if let Ok(mut pooled) = entry.pooled.lock() {
        let _ = pooled.cached_mut().pool_session_reset();
    } else {
        log::warn!("Failed to lock pooled connection {connection_id} during release cleanup");
    }

    state::recycle_pooled_connection_id(pool_id, connection_id);
    id_recycle_guard.disarm();
    0
}

pub(super) fn close_pool(pool_id: c_uint) -> c_int {
    // Lock order: transactions → pools.
    let close_result = state::with_transaction_maps_mut(|txn_maps| {
        let begins = txn_maps.begins_snapshot();
        let pool_result = state::with_pool_maps_mut(|maps| {
            if !maps.contains_pool(pool_id) {
                return Err("invalid");
            }
            if maps.pool_busy_count(pool_id) > 0 {
                return Err("busy");
            }
            if maps.has_begin_in_progress(pool_id, &begins) {
                return Err("begin");
            }
            let Some(pool) = maps.remove_pool(pool_id) else {
                return Err("gone");
            };
            let conn_ids = maps.pooled_connection_ids_for_pool(pool_id);
            let mut checked_out = Vec::with_capacity(conn_ids.len());
            for &cid in &conn_ids {
                if let Some(entry) = maps.remove_pooled_connection(cid) {
                    checked_out.push((cid, entry.pooled));
                }
            }
            maps.clear_pooled_free_ids(pool_id);
            Ok((pool, checked_out))
        });
        match pool_result {
            Some(Ok((pool, checked_out))) => {
                let mut transactions = Vec::new();
                for (cid, _) in &checked_out {
                    transactions.extend(txn_maps.take_for_connection(*cid));
                }
                Ok((pool, checked_out, transactions))
            }
            Some(Err(code)) => Err(code),
            None => Err("gone"),
        }
    });

    let (pool, checked_out, transactions) = match close_result {
        Some(Ok(v)) => v,
        Some(Err("invalid")) => {
            if let Some(mut gs) = try_lock_global_state() {
                set_error(&mut gs, format!("Invalid pool ID: {}", pool_id));
            }
            return 1;
        }
        Some(Err("busy")) => {
            if let Some(mut gs) = try_lock_global_state() {
                set_error(
                    &mut gs,
                    "Cannot close pool while connections are executing".to_string(),
                );
            }
            return 1;
        }
        Some(Err("begin")) => {
            if let Some(mut gs) = try_lock_global_state() {
                set_error(
                    &mut gs,
                    "Cannot close pool while transaction begin is in progress".to_string(),
                );
            }
            return 1;
        }
        Some(Err(_)) | None => {
            if let Some(mut gs) = try_lock_global_state() {
                set_error(
                    &mut gs,
                    format!("pool {} disappeared before removal", pool_id),
                );
            }
            return -1;
        }
    };

    for (cid, _) in &checked_out {
        state::retain_statements_not_for_connection(*cid);
    }

    state::rollback_transactions_best_effort(transactions);
    for (_, pooled) in checked_out {
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

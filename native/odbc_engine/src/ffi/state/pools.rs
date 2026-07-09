//! Dedicated lock for connection-pool maps and busy-count reservations.
//!
//! Pool checkout/checkin, busy-count bumps on every pooled query/stream, and
//! ID allocation no longer contend on the residual `GlobalState` mutex used
//! by transactions and XA. Cross-category cleanup (checkin / close / resize)
//! still acquires `GLOBAL_STATE` first when transaction begin reservations
//! must be inspected, then this lock — never the reverse.
//!
//! Lock ordering: **transactions** → **pools** → connections → streams →
//! statements → async requests → connection errors → metadata cache.

use super::super::global_state::MAX_ID_ALLOC_ATTEMPTS;
use crate::pool::{ConnectionPool, SharedPooledConnection};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

#[derive(Clone)]
pub(crate) struct PooledConnectionState {
    pub(crate) pool_id: u32,
    pub(crate) pooled: SharedPooledConnection,
}

pub(crate) struct PoolMaps {
    pools: HashMap<u32, Arc<ConnectionPool>>,
    pooled_connections: HashMap<u32, PooledConnectionState>,
    pooled_busy_counts: HashMap<u32, usize>,
    pooled_connection_busy_counts: HashMap<u32, usize>,
    pooled_free_ids: HashMap<u32, Vec<u32>>,
    next_pool_id: u32,
    next_pooled_conn_id: u32,
}

fn pool_maps() -> &'static Mutex<PoolMaps> {
    static MAPS: OnceLock<Mutex<PoolMaps>> = OnceLock::new();
    MAPS.get_or_init(|| {
        Mutex::new(PoolMaps {
            pools: HashMap::new(),
            pooled_connections: HashMap::new(),
            pooled_busy_counts: HashMap::new(),
            pooled_connection_busy_counts: HashMap::new(),
            pooled_free_ids: HashMap::new(),
            next_pool_id: 1,
            next_pooled_conn_id: 1_000_000,
        })
    })
}

fn try_lock_pool_maps() -> Option<MutexGuard<'static, PoolMaps>> {
    match pool_maps().lock() {
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

pub(crate) fn allocate_pool_id() -> Option<u32> {
    let mut maps = try_lock_pool_maps()?;
    for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
        let candidate = maps.next_pool_id;
        maps.next_pool_id = maps.next_pool_id.wrapping_add(1);
        if candidate != 0 && !maps.pools.contains_key(&candidate) {
            return Some(candidate);
        }
    }
    None
}

pub(crate) fn insert_pool(pool_id: u32, pool: Arc<ConnectionPool>) {
    if let Some(mut maps) = try_lock_pool_maps() {
        maps.pools.insert(pool_id, pool);
    }
}

pub(crate) fn get_pool(pool_id: u32) -> Option<Arc<ConnectionPool>> {
    try_lock_pool_maps().and_then(|maps| maps.pools.get(&pool_id).cloned())
}

pub(crate) fn contains_pooled_connection(conn_id: u32) -> bool {
    try_lock_pool_maps().is_some_and(|maps| maps.pooled_connections.contains_key(&conn_id))
}

pub(crate) fn get_pooled_connection(conn_id: u32) -> Option<PooledConnectionState> {
    try_lock_pool_maps().and_then(|maps| maps.pooled_connections.get(&conn_id).cloned())
}

pub(crate) fn recycle_pooled_connection_id(pool_id: u32, connection_id: u32) {
    if let Some(mut maps) = try_lock_pool_maps() {
        maps.pooled_free_ids
            .entry(pool_id)
            .or_default()
            .push(connection_id);
    }
}

/// Bump busy counts and return the pooled entry, or `None` if unknown.
pub(crate) fn reserve_pooled_runnable(conn_id: u32) -> Option<(u32, SharedPooledConnection)> {
    let mut maps = try_lock_pool_maps()?;
    let entry = maps.pooled_connections.get(&conn_id)?.clone();
    *maps.pooled_busy_counts.entry(entry.pool_id).or_insert(0) += 1;
    *maps
        .pooled_connection_busy_counts
        .entry(conn_id)
        .or_insert(0) += 1;
    Some((entry.pool_id, entry.pooled))
}

pub(crate) fn decrement_pooled_busy_counts(pool_id: u32, conn_id: u32) {
    let Some(mut maps) = try_lock_pool_maps() else {
        return;
    };
    if let Some(count) = maps.pooled_busy_counts.get_mut(&pool_id) {
        *count = count.saturating_sub(1);
        if *count == 0 {
            maps.pooled_busy_counts.remove(&pool_id);
        }
    }
    if let Some(count) = maps.pooled_connection_busy_counts.get_mut(&conn_id) {
        *count = count.saturating_sub(1);
        if *count == 0 {
            maps.pooled_connection_busy_counts.remove(&conn_id);
        }
    }
}

/// Run `f` while holding the pool maps lock (for multi-step pool close/resize).
pub(crate) fn with_pool_maps_mut<R>(f: impl FnOnce(&mut PoolMaps) -> R) -> Option<R> {
    try_lock_pool_maps().map(|mut maps| f(&mut maps))
}

impl PoolMaps {
    pub(crate) fn contains_pool(&self, pool_id: u32) -> bool {
        self.pools.contains_key(&pool_id)
    }

    pub(crate) fn get_pool(&self, pool_id: u32) -> Option<&Arc<ConnectionPool>> {
        self.pools.get(&pool_id)
    }

    pub(crate) fn insert_pool(&mut self, pool_id: u32, pool: Arc<ConnectionPool>) {
        self.pools.insert(pool_id, pool);
    }

    pub(crate) fn remove_pool(&mut self, pool_id: u32) -> Option<Arc<ConnectionPool>> {
        self.pools.remove(&pool_id)
    }

    pub(crate) fn pool_busy_count(&self, pool_id: u32) -> usize {
        self.pooled_busy_counts.get(&pool_id).copied().unwrap_or(0)
    }

    pub(crate) fn has_checked_out(&self, pool_id: u32) -> bool {
        self.pooled_connections
            .values()
            .any(|entry| entry.pool_id == pool_id)
    }

    pub(crate) fn has_begin_in_progress(
        &self,
        pool_id: u32,
        begin_conn_ids: &std::collections::HashSet<u32>,
    ) -> bool {
        begin_conn_ids.iter().any(|conn_id| {
            self.pooled_connections
                .get(conn_id)
                .map(|entry| entry.pool_id == pool_id)
                .unwrap_or(false)
        })
    }

    pub(crate) fn pooled_connection_ids_for_pool(&self, pool_id: u32) -> Vec<u32> {
        self.pooled_connections
            .iter()
            .filter(|(_, entry)| entry.pool_id == pool_id)
            .map(|(cid, _)| *cid)
            .collect()
    }

    pub(crate) fn remove_pooled_connection(
        &mut self,
        conn_id: u32,
    ) -> Option<PooledConnectionState> {
        self.pooled_connections.remove(&conn_id)
    }

    pub(crate) fn clear_pooled_free_ids(&mut self, pool_id: u32) {
        self.pooled_free_ids.remove(&pool_id);
    }

    pub(crate) fn contains_pooled_connection(&self, conn_id: u32) -> bool {
        self.pooled_connections.contains_key(&conn_id)
    }

    pub(crate) fn pooled_connection_busy_count(&self, conn_id: u32) -> usize {
        self.pooled_connection_busy_counts
            .get(&conn_id)
            .copied()
            .unwrap_or(0)
    }

    pub(crate) fn allocate_pooled_connection_id(&mut self, pool_id: u32) -> Option<u32> {
        self.pooled_free_ids
            .get_mut(&pool_id)
            .and_then(|ids| ids.pop())
            .or_else(|| {
                for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
                    let candidate = self.next_pooled_conn_id;
                    self.next_pooled_conn_id = self.next_pooled_conn_id.wrapping_add(1);
                    if candidate != 0 && !self.pooled_connections.contains_key(&candidate) {
                        return Some(candidate);
                    }
                }
                None
            })
    }

    pub(crate) fn insert_pooled_connection(
        &mut self,
        conn_id: u32,
        pool_id: u32,
        pooled: SharedPooledConnection,
    ) {
        self.pooled_connections
            .insert(conn_id, PooledConnectionState { pool_id, pooled });
    }
}

#[cfg(test)]
pub(crate) fn with_pooled_connection_mut_for_test<R>(
    conn_id: u32,
    f: impl FnOnce(&mut PooledConnectionState) -> R,
) -> Option<R> {
    try_lock_pool_maps().and_then(|mut maps| maps.pooled_connections.get_mut(&conn_id).map(f))
}

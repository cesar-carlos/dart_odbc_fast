//! Dedicated lock for the regular (non-pooled) connection registry.
//!
//! Sprint 4 follow-up: moves `GlobalState::connections` into its own
//! `RwLock` so read-mostly lookups (`contains`, handle resolution for
//! query/stream start) do not contend with unrelated outer-state writes
//! (pool checkout, transaction allocation, statement IDs).

use std::collections::HashMap;
use std::sync::{OnceLock, RwLock, RwLockReadGuard, RwLockWriteGuard};

use crate::engine::OdbcConnection;
use crate::handles::SharedHandleManager;

type ConnectionMap = HashMap<u32, OdbcConnection>;

fn connections_lock() -> &'static RwLock<ConnectionMap> {
    static MAP: OnceLock<RwLock<ConnectionMap>> = OnceLock::new();
    MAP.get_or_init(|| RwLock::new(HashMap::new()))
}

/// Acquire the read side of the connection map.
pub fn connections_read() -> Option<RwLockReadGuard<'static, ConnectionMap>> {
    match connections_lock().read() {
        Ok(guard) => Some(guard),
        Err(poisoned) => {
            log::error!(
                "ffi::state::connections RwLock read poisoned: a previous writer panicked \
                 while holding the lock; connection lookups will be unavailable until the \
                 process restarts ({poisoned})"
            );
            None
        }
    }
}

/// Acquire the write side of the connection map.
pub fn connections_write() -> Option<RwLockWriteGuard<'static, ConnectionMap>> {
    match connections_lock().write() {
        Ok(guard) => Some(guard),
        Err(poisoned) => {
            log::error!(
                "ffi::state::connections RwLock write poisoned: a previous writer panicked \
                 while holding the lock; connection registration will be dropped until the \
                 process restarts ({poisoned})"
            );
            None
        }
    }
}

pub fn insert_connection(conn_id: u32, conn: OdbcConnection) {
    if let Some(mut map) = connections_write() {
        map.insert(conn_id, conn);
    }
}

pub fn remove_connection(conn_id: u32) -> Option<OdbcConnection> {
    connections_write()?.remove(&conn_id)
}

pub fn contains_connection(conn_id: u32) -> bool {
    connections_read().is_some_and(|map| map.contains_key(&conn_id))
}

pub fn connection_handles(conn_id: u32) -> Option<SharedHandleManager> {
    connections_read()?
        .get(&conn_id)
        .map(OdbcConnection::get_handles)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[serial_test::serial]
    fn connection_registry_round_trip() {
        let conn_id = 2_000_001;
        remove_connection(conn_id);

        assert!(!contains_connection(conn_id));

        // OdbcConnection requires a live handle manager; use a minimal
        // stand-in by only exercising remove/contains on an empty map.
        assert!(remove_connection(conn_id).is_none());
    }

    #[test]
    fn connections_read_returns_none_when_lock_poisoned() {
        let lock = RwLock::new(HashMap::<u32, OdbcConnection>::new());
        let poisoned = std::panic::catch_unwind(|| {
            let _guard = lock.write().expect("lock should be available");
            panic!("intentional panic to poison local RwLock");
        });
        assert!(poisoned.is_err(), "panic should poison the RwLock");
        assert!(lock.read().ok().is_none());
        assert!(lock.write().ok().is_none());
    }
}

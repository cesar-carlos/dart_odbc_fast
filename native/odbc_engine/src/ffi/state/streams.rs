//! Dedicated lock for active ODBC stream handles.
//!
//! Sprint 4 follow-up: stream maps moved out of the monolithic
//! `GlobalState` mutex so `odbc_stream_poll_async` and
//! `odbc_stream_fetch` no longer contend with unrelated connection or
//! pool traffic.
//!
//! Lock ordering when multiple FFI locks are held: GLOBAL_STATE, then
//! stream maps, then async requests, then connection errors. Never
//! acquire GLOBAL_STATE while holding the stream maps lock.

use super::super::global_state::{set_connection_error, StreamKind, MAX_ID_ALLOC_ATTEMPTS};
use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, OnceLock};

struct StreamMaps {
    streams: HashMap<u32, StreamKind>,
    stream_connections: HashMap<u32, u32>,
    next_stream_id: u32,
}

fn stream_maps() -> &'static Mutex<StreamMaps> {
    static MAPS: OnceLock<Mutex<StreamMaps>> = OnceLock::new();
    MAPS.get_or_init(|| {
        Mutex::new(StreamMaps {
            streams: HashMap::new(),
            stream_connections: HashMap::new(),
            next_stream_id: 1,
        })
    })
}

/// Acquire the stream maps mutex. Returns `None` when poisoned (FFI
/// callers treat this as an internal error, same as `try_lock_global_state`).
fn try_lock_stream_maps() -> Option<MutexGuard<'static, StreamMaps>> {
    match stream_maps().lock() {
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

pub(crate) fn allocate_stream_id(conn_id: u32) -> u32 {
    let Some(mut maps) = try_lock_stream_maps() else {
        return 0;
    };
    for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
        let candidate = maps.next_stream_id;
        maps.next_stream_id = maps.next_stream_id.wrapping_add(1);
        if candidate != 0 && !maps.streams.contains_key(&candidate) {
            return candidate;
        }
    }
    drop(maps);
    if let Some(mut state) = super::super::global_state::try_lock_global_state() {
        set_connection_error(
            &mut state,
            conn_id,
            "Failed to allocate stream ID".to_string(),
        );
    }
    0
}

pub(crate) fn insert_stream(stream_id: u32, conn_id: u32, stream: StreamKind) {
    if let Some(mut maps) = try_lock_stream_maps() {
        maps.streams.insert(stream_id, stream);
        maps.stream_connections.insert(stream_id, conn_id);
    }
}

pub(crate) fn stream_connection_id(stream_id: u32) -> Option<u32> {
    try_lock_stream_maps().and_then(|maps| maps.stream_connections.get(&stream_id).copied())
}

pub(crate) fn remove_stream(stream_id: u32) -> Option<StreamKind> {
    try_lock_stream_maps().and_then(|mut maps| {
        maps.stream_connections.remove(&stream_id);
        maps.streams.remove(&stream_id)
    })
}

pub(crate) fn with_stream_mut<R>(
    stream_id: u32,
    f: impl FnOnce(&mut StreamKind) -> R,
) -> Option<R> {
    try_lock_stream_maps().and_then(|mut maps| maps.streams.get_mut(&stream_id).map(f))
}

pub(crate) fn reinsert_stream(stream_id: u32, stream: StreamKind) {
    if let Some(mut maps) = try_lock_stream_maps() {
        maps.streams.insert(stream_id, stream);
    }
}

pub(crate) fn request_stream_cancel(stream_id: u32) -> bool {
    try_lock_stream_maps()
        .and_then(|maps| maps.streams.get(&stream_id).map(|s| s.cancel()))
        .is_some()
}

pub(crate) fn close_stream(stream_id: u32) -> bool {
    if let Some(mut maps) = try_lock_stream_maps() {
        if let Some(stream) = maps.streams.remove(&stream_id) {
            stream.cancel();
            maps.stream_connections.remove(&stream_id);
            return true;
        }
    }
    false
}

pub(crate) fn cancel_streams_for_connection(conn_id: u32) {
    if let Some(mut maps) = try_lock_stream_maps() {
        let streams_to_drop: Vec<u32> = maps
            .stream_connections
            .iter()
            .filter_map(|(stream_id, stream_conn_id)| {
                (*stream_conn_id == conn_id).then_some(*stream_id)
            })
            .collect();
        for stream_id in streams_to_drop {
            if let Some(stream) = maps.streams.remove(&stream_id) {
                stream.cancel();
            }
            maps.stream_connections.remove(&stream_id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::allocate_stream_id;

    #[test]
    fn allocate_stream_id_returns_non_zero() {
        let id = allocate_stream_id(42);
        assert_ne!(id, 0);
        let _ = super::close_stream(id);
    }
}

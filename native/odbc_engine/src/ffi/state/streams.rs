//! Dedicated lock for active ODBC stream handles.
//!
//! Sprint 4 follow-up: stream maps moved out of the monolithic
//! `GlobalState` mutex so `odbc_stream_poll_async` and
//! `odbc_stream_fetch` no longer contend with unrelated connection or
//! pool traffic.
//!
//! Lock ordering when multiple FFI locks are held: GLOBAL_STATE, then
//! transactions, then pools, then connections, then stream maps, then
//! statements, then async requests, then connection errors. Never acquire
//! GLOBAL_STATE while holding the stream maps lock.

use super::super::global_state::{StreamKind, MAX_ID_ALLOC_ATTEMPTS};
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

/// Allocates a fresh non-zero stream ID, or returns `0` when the ID space is
/// exhausted after [`MAX_ID_ALLOC_ATTEMPTS`] collisions.
///
/// Deliberately never touches `GLOBAL_STATE`: callers (`reserve_stream_start`,
/// `stream_start`) invoke this while already holding the global mutex, so
/// reporting the failure here would re-lock the same non-reentrant mutex on
/// the same thread (deadlock/panic). Callers own the error reporting.
pub(crate) fn allocate_stream_id(_conn_id: u32) -> u32 {
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

/// Temporarily takes a stream out of the map for a fetch, so the map lock is
/// not held across a potentially blocking `copy_next_chunk`. The
/// `stream_connections` entry is intentionally kept: the stream is expected to
/// be handed back via [`reinsert_stream`], and dropping the mapping here would
/// orphan the stream from `cancel_streams_for_connection` on disconnect and
/// downgrade per-connection error reporting to the legacy global slot.
pub(crate) fn remove_stream(stream_id: u32) -> Option<StreamKind> {
    try_lock_stream_maps().and_then(|mut maps| maps.streams.remove(&stream_id))
}

pub(crate) fn with_stream_mut<R>(
    stream_id: u32,
    f: impl FnOnce(&mut StreamKind) -> R,
) -> Option<R> {
    try_lock_stream_maps().and_then(|mut maps| maps.streams.get_mut(&stream_id).map(f))
}

/// Hands a stream taken by [`remove_stream`] back to the map after a fetch.
///
/// If the `stream_connections` entry disappeared while the stream was checked
/// out (the owning connection was disconnected and
/// [`cancel_streams_for_connection`] ran), the stream is cancelled and dropped
/// instead of being resurrected as an orphan that no cleanup path would ever
/// reach again.
pub(crate) fn reinsert_stream(stream_id: u32, stream: StreamKind) {
    if let Some(mut maps) = try_lock_stream_maps() {
        if maps.stream_connections.contains_key(&stream_id) {
            maps.streams.insert(stream_id, stream);
        } else {
            stream.cancel();
        }
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
    use super::*;
    use crate::engine::{StreamState, StreamingState};

    fn dummy_stream() -> StreamKind {
        StreamKind::Buffer(StreamState::InMemory(StreamingState {
            data: Vec::new(),
            offset: 0,
            chunk_size: 4,
        }))
    }

    #[test]
    #[serial_test::serial]
    fn allocate_stream_id_returns_non_zero() {
        let id = allocate_stream_id(42);
        assert_ne!(id, 0);
        let _ = super::close_stream(id);
    }

    /// Regression: `remove_stream` used to drop the `stream_connections`
    /// mapping during a fetch checkout, so after the first fetch a disconnect
    /// could no longer find (and cancel) the stream and per-connection error
    /// reporting fell back to the legacy global slot.
    #[test]
    #[serial_test::serial]
    fn should_preserve_connection_mapping_when_stream_checked_out_for_fetch() {
        let conn_id = 3_000_001;
        let stream_id = allocate_stream_id(conn_id);
        assert_ne!(stream_id, 0);
        insert_stream(stream_id, conn_id, dummy_stream());

        let taken = remove_stream(stream_id).expect("stream registered above");
        assert_eq!(
            stream_connection_id(stream_id),
            Some(conn_id),
            "connection mapping must survive the fetch checkout window"
        );

        reinsert_stream(stream_id, taken);
        assert_eq!(stream_connection_id(stream_id), Some(conn_id));

        assert!(close_stream(stream_id));
        assert_eq!(stream_connection_id(stream_id), None);
    }

    /// Regression: a stream reinserted after its connection was cleaned up
    /// (disconnect during an in-flight fetch) must not be resurrected as an
    /// orphan unreachable by any cleanup path.
    #[test]
    #[serial_test::serial]
    fn should_drop_stream_reinserted_after_connection_cleanup() {
        let conn_id = 3_000_002;
        let stream_id = allocate_stream_id(conn_id);
        assert_ne!(stream_id, 0);
        insert_stream(stream_id, conn_id, dummy_stream());

        let taken = remove_stream(stream_id).expect("stream registered above");
        cancel_streams_for_connection(conn_id);
        assert_eq!(stream_connection_id(stream_id), None);

        reinsert_stream(stream_id, taken);
        assert!(
            remove_stream(stream_id).is_none(),
            "stream must not be resurrected after its connection was cleaned up"
        );
    }

    /// Regression: on ID exhaustion `allocate_stream_id` used to acquire
    /// `GLOBAL_STATE` to record an error, deadlocking every caller that
    /// already holds the global mutex (`reserve_stream_start`,
    /// `stream_start`). It must fail with `0` without touching that lock.
    #[test]
    #[serial_test::serial]
    fn should_return_zero_on_id_exhaustion_while_global_state_lock_is_held() {
        let conn_id = 3_000_003;
        let base = allocate_stream_id(conn_id);
        assert_ne!(base, 0);

        let occupied: Vec<u32> = (1..=MAX_ID_ALLOC_ATTEMPTS)
            .map(|offset| base.wrapping_add(offset))
            .collect();
        for &id in &occupied {
            insert_stream(id, conn_id, dummy_stream());
        }

        let global_guard = crate::ffi::global_state::try_lock_global_state()
            .expect("global state lock available in test");
        let exhausted = allocate_stream_id(conn_id);
        drop(global_guard);

        assert_eq!(
            exhausted, 0,
            "exhausted ID space must report 0 instead of deadlocking on GLOBAL_STATE"
        );

        for &id in &occupied {
            let _ = close_stream(id);
        }
    }
}

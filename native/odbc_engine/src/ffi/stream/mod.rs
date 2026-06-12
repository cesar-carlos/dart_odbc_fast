// Allow FFI functions to dereference raw pointers without being marked unsafe
// This is expected and safe for extern "C" FFI boundaries
#![allow(clippy::not_unsafe_ptr_arg_deref)]

mod helpers;

use super::global::*;
use super::prelude::*;
use helpers::{
    apply_stream_fetch_result, parse_stream_sql, require_stream_fetch_ptrs, resolve_chunk_size,
    resolve_fetch_size,
};

use std::os::raw::{c_char, c_int, c_uint};

/// Start streaming query execution.
#[no_mangle]
pub extern "C" fn odbc_stream_start(
    conn_id: c_uint,
    sql: *const c_char,
    chunk_size: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        let Some(sql_str) = parse_stream_sql(sql) else {
            return 0;
        };

        let chunk_size = resolve_chunk_size(chunk_size);
        let spill_threshold_mb = std::env::var("ODBC_STREAM_SPILL_THRESHOLD_MB")
            .ok()
            .and_then(|s| s.parse::<usize>().ok())
            .filter(|&t| t > 0);

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };
        let mut target = match take_runnable_connection(&mut state, conn_id) {
            Ok(target) => target,
            Err(e) => {
                set_connection_structured_error(&mut state, conn_id, e.to_structured());
                return 0;
            }
        };
        drop(state);

        let executor = StreamingExecutor::new(chunk_size);
        let stream_state = match &mut target {
            RunnableConnection::Regular(conn_arc) => {
                let conn_guard = match conn_arc.lock() {
                    Ok(g) => g,
                    Err(_) => {
                        let Some(mut state) = try_lock_global_state() else {
                            return 0;
                        };
                        set_connection_error(
                            &mut state,
                            conn_id,
                            "Failed to lock connection".to_string(),
                        );
                        return 0;
                    }
                };
                if let Some(threshold) = spill_threshold_mb {
                    executor.execute_streaming_with_spill(
                        conn_guard.connection(),
                        sql_str,
                        Some(threshold),
                    )
                } else {
                    executor
                        .execute_streaming(conn_guard.connection(), sql_str)
                        .map(crate::engine::StreamState::InMemory)
                }
            }
            RunnableConnection::Pooled { pooled, .. } => match pooled.lock() {
                Ok(conn_guard) => {
                    if let Some(threshold) = spill_threshold_mb {
                        executor.execute_streaming_with_spill(
                            conn_guard.get_connection(),
                            sql_str,
                            Some(threshold),
                        )
                    } else {
                        executor
                            .execute_streaming(conn_guard.get_connection(), sql_str)
                            .map(crate::engine::StreamState::InMemory)
                    }
                }
                Err(_) => Err(OdbcError::InternalError(
                    "Failed to lock pooled connection".to_string(),
                )),
            },
        };

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };
        restore_pooled_connection(&mut state, conn_id, target);

        match stream_state {
            Ok(stream_state) => {
                let stream_id = {
                    let mut id = 0u32;
                    for _ in 0..MAX_ID_ALLOC_ATTEMPTS {
                        let candidate = state.next_stream_id;
                        state.next_stream_id = state.next_stream_id.wrapping_add(1);
                        if candidate != 0 && !state.streams.contains_key(&candidate) {
                            id = candidate;
                            break;
                        }
                    }
                    if id == 0 {
                        set_connection_error(
                            &mut state,
                            conn_id,
                            "Failed to allocate stream ID".to_string(),
                        );
                        return 0;
                    }
                    id
                };
                state
                    .streams
                    .insert(stream_id, StreamKind::Buffer(stream_state));
                state.stream_connections.insert(stream_id, conn_id);
                stream_id
            }
            Err(e) => {
                set_connection_error(
                    &mut state,
                    conn_id,
                    format!("odbc_stream_start failed: {}", e),
                );
                0
            }
        }
    })
}

/// Start batched streaming (cursor-based; bounded memory).
/// conn_id: connection ID
/// sql: null-terminated UTF-8 SQL query
/// fetch_size: rows per batch
/// chunk_size: bytes per FFI chunk
/// Returns: stream_id (>0) on success, 0 on failure
#[no_mangle]
pub extern "C" fn odbc_stream_start_batched(
    conn_id: c_uint,
    sql: *const c_char,
    fetch_size: c_uint,
    chunk_size: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        let Some(sql_str) = parse_stream_sql(sql) else {
            return 0;
        };

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };

        let reservation = match reserve_stream_start(&mut state, conn_id) {
            Ok(reservation) => reservation,
            Err(e) => {
                set_connection_structured_error(&mut state, conn_id, e.to_structured());
                return 0;
            }
        };

        let fetch_size = resolve_fetch_size(fetch_size);
        let chunk_size = resolve_chunk_size(chunk_size);
        let sql_owned = sql_str.to_string();

        drop(state);

        let executor = StreamingExecutor::new(chunk_size);
        let start_result = match &reservation.target {
            StreamStartTarget::Regular { handles } => executor.start_batched_stream(
                handles.clone(),
                conn_id,
                sql_owned,
                fetch_size,
                chunk_size,
                ResultEncoding::RowMajor,
            ),
            StreamStartTarget::Pooled { pool_id, pooled } => executor.start_batched_stream_pooled(
                Arc::clone(pooled),
                sql_owned,
                fetch_size,
                chunk_size,
                Some(pooled_stream_completion(conn_id, *pool_id)),
                ResultEncoding::RowMajor,
            ),
        };

        match start_result {
            Ok(batched_state) => {
                let Some(mut state) = try_lock_global_state() else {
                    return 0;
                };
                insert_stream(
                    &mut state,
                    reservation.stream_id,
                    conn_id,
                    StreamKind::Batched(batched_state),
                )
            }
            Err(e) => {
                release_pooled_stream_reservation(conn_id, &reservation.target);
                let Some(mut state) = try_lock_global_state() else {
                    return 0;
                };
                set_connection_error(
                    &mut state,
                    conn_id,
                    format!("odbc_stream_start_batched failed: {}", e),
                );
                0
            }
        }
    })
}

/// Start batched streaming with an explicit result wire encoding (v4.2).
///
/// `result_encoding`: 0=row-major v1, 1=columnar v2, 2=columnar v2 compressed.
/// Older clients keep using `odbc_stream_start_batched` (row-major).
#[no_mangle]
pub extern "C" fn odbc_stream_start_batched_options(
    conn_id: c_uint,
    sql: *const c_char,
    fetch_size: c_uint,
    chunk_size: c_uint,
    result_encoding: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        let Some(sql_str) = parse_stream_sql(sql) else {
            return 0;
        };

        let encoding = match ResultEncoding::from_wire(result_encoding) {
            Some(encoding) => encoding,
            None => {
                let Some(mut state) = try_lock_global_state() else {
                    return 0;
                };
                set_connection_error(
                    &mut state,
                    conn_id,
                    format!("Invalid result_encoding: {}", result_encoding),
                );
                return 0;
            }
        };

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };

        let reservation = match reserve_stream_start(&mut state, conn_id) {
            Ok(reservation) => reservation,
            Err(e) => {
                set_connection_structured_error(&mut state, conn_id, e.to_structured());
                return 0;
            }
        };

        let fetch_size = resolve_fetch_size(fetch_size);
        let chunk_size = resolve_chunk_size(chunk_size);
        let sql_owned = sql_str.to_string();

        drop(state);

        let executor = StreamingExecutor::new(chunk_size);
        let start_result = match &reservation.target {
            StreamStartTarget::Regular { handles } => executor.start_batched_stream(
                handles.clone(),
                conn_id,
                sql_owned,
                fetch_size,
                chunk_size,
                encoding,
            ),
            StreamStartTarget::Pooled { pool_id, pooled } => executor.start_batched_stream_pooled(
                Arc::clone(pooled),
                sql_owned,
                fetch_size,
                chunk_size,
                Some(pooled_stream_completion(conn_id, *pool_id)),
                encoding,
            ),
        };

        match start_result {
            Ok(batched_state) => {
                let Some(mut state) = try_lock_global_state() else {
                    return 0;
                };
                insert_stream(
                    &mut state,
                    reservation.stream_id,
                    conn_id,
                    StreamKind::Batched(batched_state),
                )
            }
            Err(e) => {
                release_pooled_stream_reservation(conn_id, &reservation.target);
                let Some(mut state) = try_lock_global_state() else {
                    return 0;
                };
                set_connection_error(
                    &mut state,
                    conn_id,
                    format!("odbc_stream_start_batched_options failed: {}", e),
                );
                0
            }
        }
    })
}

/// Start async batched stream execution. The query runs in a background worker and
/// stream readiness is observable via `odbc_stream_poll_async`.
/// Returns stream_id (>0) on success, 0 on error.
#[no_mangle]
pub extern "C" fn odbc_stream_start_async(
    conn_id: c_uint,
    sql: *const c_char,
    fetch_size: c_uint,
    chunk_size: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        let Some(sql_str) = parse_stream_sql(sql) else {
            return 0;
        };

        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };

        let reservation = match reserve_stream_start(&mut state, conn_id) {
            Ok(reservation) => reservation,
            Err(e) => {
                set_connection_structured_error(&mut state, conn_id, e.to_structured());
                return 0;
            }
        };

        let fetch_size = resolve_fetch_size(fetch_size);
        let chunk_size = resolve_chunk_size(chunk_size);
        let sql_owned = sql_str.to_string();

        drop(state);

        let executor = StreamingExecutor::new(chunk_size);
        let start_result = match &reservation.target {
            StreamStartTarget::Regular { handles } => executor.start_async_stream(
                handles.clone(),
                conn_id,
                sql_owned,
                fetch_size,
                chunk_size,
                ResultEncoding::RowMajor,
            ),
            StreamStartTarget::Pooled { pool_id, pooled } => executor.start_async_stream_pooled(
                Arc::clone(pooled),
                sql_owned,
                fetch_size,
                chunk_size,
                Some(pooled_stream_completion(conn_id, *pool_id)),
                ResultEncoding::RowMajor,
            ),
        };

        match start_result {
            Ok(async_state) => {
                let Some(mut state) = try_lock_global_state() else {
                    return 0;
                };
                insert_stream(
                    &mut state,
                    reservation.stream_id,
                    conn_id,
                    StreamKind::AsyncBatched(async_state),
                )
            }
            Err(e) => {
                release_pooled_stream_reservation(conn_id, &reservation.target);
                let Some(mut state) = try_lock_global_state() else {
                    return 0;
                };
                set_connection_error(
                    &mut state,
                    conn_id,
                    format!("odbc_stream_start_async failed: {}", e),
                );
                0
            }
        }
    })
}

/// Start a streaming **multi-result** batch (M8 in v3.3.0).
///
/// Like `odbc_stream_start_batched`, but the produced chunks belong to a
/// frame-based wire format where every frame carries one multi-result item:
///
/// ```text
/// [tag: u8] [len: u32 LE] [payload: len bytes]
/// ```
///
/// `tag = 0` payload is a `binary_protocol` row-buffer; `tag = 1` payload is
/// `i64 LE` row count. Consumers should accumulate raw chunks into a frame
/// buffer and parse items as they complete, exactly like the Dart
/// `MultiResultStreamDecoder`.
///
/// Reuses the existing fetch/cancel/close FFIs (`odbc_stream_fetch`,
/// `odbc_stream_cancel`, `odbc_stream_close`).
///
/// Returns: stream_id (>0) on success, 0 on failure.
#[no_mangle]
pub extern "C" fn odbc_stream_multi_start_batched(
    conn_id: c_uint,
    sql: *const c_char,
    chunk_size: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        let Some(sql_str) = parse_stream_sql(sql) else {
            return 0;
        };
        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };
        let reservation = match reserve_stream_start(&mut state, conn_id) {
            Ok(reservation) => reservation,
            Err(e) => {
                set_connection_structured_error(&mut state, conn_id, e.to_structured());
                return 0;
            }
        };
        let chunk_size = resolve_chunk_size(chunk_size);
        let sql_owned = sql_str.to_string();
        drop(state);

        let start_result = match &reservation.target {
            StreamStartTarget::Regular { handles } => crate::engine::start_multi_batched_stream(
                handles.clone(),
                conn_id,
                sql_owned,
                chunk_size,
            ),
            StreamStartTarget::Pooled { pool_id, pooled } => {
                crate::engine::start_multi_batched_stream_pooled(
                    Arc::clone(pooled),
                    sql_owned,
                    chunk_size,
                    Some(pooled_stream_completion(conn_id, *pool_id)),
                )
            }
        };

        match start_result {
            Ok(batched_state) => {
                let Some(mut state) = try_lock_global_state() else {
                    return 0;
                };
                insert_stream(
                    &mut state,
                    reservation.stream_id,
                    conn_id,
                    StreamKind::Batched(batched_state),
                )
            }
            Err(e) => {
                release_pooled_stream_reservation(conn_id, &reservation.target);
                let Some(mut state) = try_lock_global_state() else {
                    return 0;
                };
                set_connection_error(
                    &mut state,
                    conn_id,
                    format!("odbc_stream_multi_start_batched failed: {}", e),
                );
                0
            }
        }
    })
}

/// Async variant of [`odbc_stream_multi_start_batched`]. Status is observable
/// via the existing `odbc_stream_poll_async`.
///
/// Returns: stream_id (>0) on success, 0 on failure.
#[no_mangle]
pub extern "C" fn odbc_stream_multi_start_async(
    conn_id: c_uint,
    sql: *const c_char,
    chunk_size: c_uint,
) -> c_uint {
    crate::ffi_guard_id!(c_uint, {
        let Some(sql_str) = parse_stream_sql(sql) else {
            return 0;
        };
        let Some(mut state) = try_lock_global_state() else {
            return 0;
        };
        let reservation = match reserve_stream_start(&mut state, conn_id) {
            Ok(reservation) => reservation,
            Err(e) => {
                set_connection_structured_error(&mut state, conn_id, e.to_structured());
                return 0;
            }
        };
        let chunk_size = resolve_chunk_size(chunk_size);
        let sql_owned = sql_str.to_string();
        drop(state);

        let start_result = match &reservation.target {
            StreamStartTarget::Regular { handles } => crate::engine::start_multi_async_stream(
                handles.clone(),
                conn_id,
                sql_owned,
                chunk_size,
            ),
            StreamStartTarget::Pooled { pool_id, pooled } => {
                crate::engine::start_multi_async_stream_pooled(
                    Arc::clone(pooled),
                    sql_owned,
                    chunk_size,
                    Some(pooled_stream_completion(conn_id, *pool_id)),
                )
            }
        };

        match start_result {
            Ok(async_state) => {
                let Some(mut state) = try_lock_global_state() else {
                    return 0;
                };
                insert_stream(
                    &mut state,
                    reservation.stream_id,
                    conn_id,
                    StreamKind::AsyncBatched(async_state),
                )
            }
            Err(e) => {
                release_pooled_stream_reservation(conn_id, &reservation.target);
                let Some(mut state) = try_lock_global_state() else {
                    return 0;
                };
                set_connection_error(
                    &mut state,
                    conn_id,
                    format!("odbc_stream_multi_start_async failed: {}", e),
                );
                0
            }
        }
    })
}

/// Poll async stream status.
/// out_status: 0=pending, 1=ready, 2=done, -1=error, -2=cancelled
/// Returns: 0 on success, non-zero on failure.
#[no_mangle]
pub extern "C" fn odbc_stream_poll_async(stream_id: c_uint, out_status: *mut c_int) -> c_int {
    crate::ffi_guard_int!({
        if out_status.is_null() {
            return -1;
        }

        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };

        let stream = match state.streams.get_mut(&stream_id) {
            Some(s) => s,
            None => {
                set_error(&mut state, format!("Invalid stream ID: {}", stream_id));
                return -1;
            }
        };

        let status = stream.poll_status();
        // SAFETY: `out_status` is non-null (checked above).
        unsafe {
            *out_status = status;
        }
        0
    })
}

/// Fetch next chunk from stream
/// stream_id: stream ID from odbc_stream_start
/// out_buf: output buffer
/// buf_len: buffer size
/// out_written: bytes written
/// has_more: 1 if more data available, 0 otherwise
/// Returns: 0 on success, non-zero on error
#[no_mangle]
pub extern "C" fn odbc_stream_fetch(
    stream_id: c_uint,
    out_buf: *mut u8,
    buf_len: c_uint,
    out_written: *mut c_uint,
    has_more: *mut u8,
) -> c_int {
    crate::ffi_guard_int!({
        if !require_stream_fetch_ptrs(out_buf, out_written, has_more) {
            return -1;
        }

        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };

        let stream_conn_id = state.stream_connections.get(&stream_id).copied();

        let mut stream = match state.streams.remove(&stream_id) {
            Some(s) => s,
            None => {
                set_error(&mut state, format!("Invalid stream ID: {}", stream_id));
                return -1;
            }
        };
        drop(state);

        // SAFETY: `out_buf` is non-null (checked above); caller guarantees the
        // buffer is writable for `buf_len` bytes for the duration of this call.
        let out_slice = unsafe { std::slice::from_raw_parts_mut(out_buf, buf_len as usize) };
        let fetch_result = stream.copy_next_chunk(out_slice);

        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };
        state.streams.insert(stream_id, stream);

        apply_stream_fetch_result(
            &mut state,
            stream_conn_id,
            buf_len,
            out_written,
            has_more,
            fetch_result,
        )
    })
}

/// Request cancellation of a batched stream. Only effective for streams
/// created with odbc_stream_start_batched; no-op for buffer-mode streams.
/// The worker checks the cancellation flag between batches and exits early.
/// Returns: 0 on success, non-zero if stream_id is invalid
#[no_mangle]
pub extern "C" fn odbc_stream_cancel(stream_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };

        if let Some(stream) = state.streams.get(&stream_id) {
            stream.cancel();
            0
        } else {
            set_error(&mut state, format!("Invalid stream ID: {}", stream_id));
            1
        }
    })
}

/// Close stream
/// stream_id: stream ID to close
/// Returns: 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn odbc_stream_close(stream_id: c_uint) -> c_int {
    crate::ffi_guard_int!({
        let Some(mut state) = try_lock_global_state() else {
            return -1;
        };

        if let Some(stream) = state.streams.remove(&stream_id) {
            stream.cancel();
            state.stream_connections.remove(&stream_id);
            0
        } else {
            set_error(&mut state, format!("Invalid stream ID: {}", stream_id));
            1
        }
    })
}

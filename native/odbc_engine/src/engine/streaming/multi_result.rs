use super::batched_fetch::drain_cursor_in_batches;
use super::chunk::BatchBufferPool;
use super::state::{AsyncStreamingState, BatchedMessage, BatchedStreamingState, WorkerCompletion};
use crate::engine::query::ResultEncoding;
use crate::error::{OdbcError, Result};
use crate::handles::SharedHandleManager;
use crate::pool::SharedPooledConnection;
use odbc_api::handles::{AsStatementRef, SqlResult, Statement};
#[cfg(not(feature = "statement-handle-reuse"))]
use odbc_api::Connection;
use odbc_api::{Cursor, CursorImpl, Prepared, ResultSetMetadata};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;

/// Item-frame tags for the streaming multi-result wire format (M8).
pub const MULTI_STREAM_ITEM_TAG_RESULT_SET: u8 = 0;
pub const MULTI_STREAM_ITEM_TAG_ROW_COUNT: u8 = 1;
/// Continuation batch for the current result set (v4.2 batched per cursor).
pub const MULTI_STREAM_ITEM_TAG_RESULT_SET_BATCH: u8 = 2;

/// Default ODBC rows per batch when streaming multi-result cursors.
#[allow(
    dead_code,
    reason = "Documented default for multi-stream FFI; wire default is resolve_fetch_size(0)."
)]
pub(crate) const DEFAULT_MULTI_STREAM_FETCH_SIZE: usize = 100;

/// Bounded queue depth between the multi-stream producer thread and the
/// consumer. Depth 2 lets the producer pre-buffer one frame while Dart/FFI
/// copies the current one.
const MULTI_STREAM_CHANNEL_DEPTH: usize = 2;

/// Drive a prepared statement that may yield multiple result sets and call
/// `on_item` for **every** result set or row-count, in order. Each item is
/// wire-framed as `[tag: u8][len: u32 LE][payload]`. Used by the streaming
/// FFIs to surface items lazily instead of materialising the whole batch.
///
/// Mirrors `ExecutionEngine::collect_multi_results` (see M1 fix in v3.2.0)
/// but pushes each item through a callback instead of accumulating them.
#[cfg(not(feature = "statement-handle-reuse"))]
fn drive_multi_result_stream<F>(
    conn: &Connection<'static>,
    sql: &str,
    fetch_size: usize,
    result_encoding: ResultEncoding,
    on_item: &mut F,
    cancel_requested: Option<Arc<AtomicBool>>,
    buffer_pool: Option<&BatchBufferPool>,
    param_bytes: Option<&[u8]>,
) -> Result<()>
where
    F: FnMut(Vec<u8>) -> Result<()>,
{
    let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;
    drive_prepared_multi_result_stream(
        &mut stmt,
        fetch_size,
        result_encoding,
        on_item,
        cancel_requested,
        buffer_pool,
        param_bytes,
    )
}

fn drive_prepared_multi_result_stream<S, F>(
    stmt: &mut Prepared<S>,
    fetch_size: usize,
    result_encoding: ResultEncoding,
    on_item: &mut F,
    cancel_requested: Option<Arc<AtomicBool>>,
    buffer_pool: Option<&BatchBufferPool>,
    param_bytes: Option<&[u8]>,
) -> Result<()>
where
    S: AsStatementRef,
    F: FnMut(Vec<u8>) -> Result<()>,
{
    let cancel_check = || {
        cancel_requested
            .as_ref()
            .is_some_and(|c| c.load(Ordering::Relaxed))
    };

    // Encode the initial result inside a scope that bounds the cursor's
    // borrow on `stmt`. Same SQLCloseCursor avoidance pattern as
    // `ExecutionEngine::execute_multi_result_inner` (M1 fix in v3.2.0).
    let had_initial_cursor = {
        let initial_cursor = execute_multi_stream_cursor(stmt, param_bytes)?;
        if let Some(cursor) = initial_cursor {
            if cancel_check() {
                return Err(OdbcError::Cancelled);
            }
            let cursor = encode_cursor_batched(
                cursor,
                fetch_size,
                result_encoding,
                on_item,
                cancel_check,
                buffer_pool,
            )?;
            let _stmt_ref = cursor.into_stmt();
            true
        } else {
            false
        }
    };

    if !had_initial_cursor {
        let rc = stmt
            .row_count()
            .map_err(OdbcError::from)?
            .map(|n| n as i64)
            .unwrap_or(0);
        let payload = rc.to_le_bytes();
        on_item(frame_item_from_slice(
            MULTI_STREAM_ITEM_TAG_ROW_COUNT,
            &payload,
        )?)?;
    }

    loop {
        if cancel_check() {
            return Err(OdbcError::Cancelled);
        }
        // SAFETY: no live cursor borrow at this point — the cursor block
        // above either consumed the cursor via `into_stmt()` or never
        // produced one. `Statement::more_results` is unsafe precisely
        // because it would invalidate any outstanding cursor.
        let advance = unsafe { stmt.as_stmt_ref().more_results() };
        match advance {
            SqlResult::NoData => {
                return if cancel_check() {
                    Err(OdbcError::Cancelled)
                } else {
                    Ok(())
                };
            }
            SqlResult::Success(()) | SqlResult::SuccessWithInfo(()) => { /* continue */ }
            SqlResult::Error { .. } => {
                let err = advance
                    .into_result(&stmt.as_stmt_ref())
                    .err()
                    .map(OdbcError::from)
                    .unwrap_or_else(|| OdbcError::OdbcApi("SQLMoreResults failed".to_string()));
                let s = err.sqlstate();
                if s == [b'0', b'2', b'0', b'0', b'0'] {
                    return Ok(());
                }
                return Err(err);
            }
            SqlResult::NeedData | SqlResult::StillExecuting => {
                return Err(OdbcError::OdbcApi(
                    "Unexpected SQLMoreResults state in streaming worker".to_string(),
                ));
            }
        }

        let cols = stmt
            .as_stmt_ref()
            .num_result_cols()
            .into_result(&stmt.as_stmt_ref())
            .map_err(OdbcError::from)?;
        if cols > 0 {
            // SAFETY: just observed cols > 0 with no other live borrow.
            let cursor = unsafe { CursorImpl::new(stmt.as_stmt_ref()) };
            let cursor = encode_cursor_batched(
                cursor,
                fetch_size,
                result_encoding,
                on_item,
                cancel_check,
                buffer_pool,
            )?;
            let _stmt_ref = cursor.into_stmt();
        } else {
            let rc = stmt
                .as_stmt_ref()
                .row_count()
                .into_result(&stmt.as_stmt_ref())
                .map_err(OdbcError::from)?;
            let payload = (rc as i64).to_le_bytes();
            on_item(frame_item_from_slice(
                MULTI_STREAM_ITEM_TAG_ROW_COUNT,
                &payload,
            )?)?;
        }
    }
}

/// Drain `cursor` in fetch-sized batches, framing each encoded batch as a
/// multi-result item. Returns the cursor so the caller can `into_stmt()` for
/// `SQLMoreResults`.
///
/// FOR JSON coalescing is skipped here (same rationale as single-result
/// batched streaming): chunks would be split across batches.
fn execute_multi_stream_cursor<'a, S: AsStatementRef>(
    stmt: &'a mut Prepared<S>,
    param_bytes: Option<&[u8]>,
) -> Result<Option<CursorImpl<odbc_api::handles::StatementRef<'a>>>> {
    let Some(bytes) = param_bytes.filter(|b| !b.is_empty()) else {
        return stmt.execute(()).map_err(OdbcError::from);
    };
    use crate::protocol::bound_param::{ParamDirection, ParamList};
    use crate::protocol::{
        deserialize_param_buffer, has_null_param, param_values_to_input_params,
        param_values_to_input_params_with_descriptions,
        param_values_to_input_params_with_inference,
    };
    let list = deserialize_param_buffer(bytes)?;
    let params = match list {
        ParamList::Legacy(params) => params,
        ParamList::Directed(bound) => {
            if bound
                .iter()
                .any(|item| item.direction != ParamDirection::Input)
            {
                return Err(OdbcError::ValidationError(
                    "multi-result stream parameters must be input-only".to_string(),
                ));
            }
            bound.into_iter().map(|item| item.value).collect()
        }
    };
    if params.is_empty() {
        return stmt.execute(()).map_err(OdbcError::from);
    }
    if has_null_param(&params) {
        if let Some(parameters) = param_values_to_input_params_with_inference(&params)? {
            return stmt.execute(parameters.as_slice()).map_err(OdbcError::from);
        }
        let descriptions = stmt
            .parameter_descriptions()
            .map_err(OdbcError::from)?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(OdbcError::from)?;
        let parameters = param_values_to_input_params_with_descriptions(&params, &descriptions)?;
        return stmt.execute(parameters.as_slice()).map_err(OdbcError::from);
    }
    let parameters = param_values_to_input_params(&params)?;
    stmt.execute(parameters.as_slice()).map_err(OdbcError::from)
}

fn encode_cursor_batched<C, F>(
    cursor: C,
    fetch_size: usize,
    result_encoding: ResultEncoding,
    on_item: &mut F,
    cancel_check: impl Fn() -> bool,
    buffer_pool: Option<&BatchBufferPool>,
) -> Result<C>
where
    C: Cursor + ResultSetMetadata,
    F: FnMut(Vec<u8>) -> Result<()>,
{
    let mut first_batch = true;
    drain_cursor_in_batches(
        cursor,
        fetch_size,
        result_encoding,
        on_item,
        &mut || {
            let tag = if first_batch {
                MULTI_STREAM_ITEM_TAG_RESULT_SET
            } else {
                MULTI_STREAM_ITEM_TAG_RESULT_SET_BATCH
            };
            first_batch = false;
            Some(tag)
        },
        cancel_check,
        buffer_pool,
    )
}

#[cfg(test)]
pub(crate) fn frame_item(tag: u8, mut payload: Vec<u8>) -> Result<Vec<u8>> {
    let payload_len: u32 = payload.len().try_into().map_err(|_| {
        OdbcError::ResourceLimitReached(format!(
            "multi-result stream item payload exceeds u32: {}",
            payload.len()
        ))
    })?;
    let capacity = payload
        .len()
        .checked_add(5)
        .ok_or_else(|| OdbcError::ResourceLimitReached("stream item size overflow".to_string()))?;
    let mut out = Vec::with_capacity(capacity);
    out.push(tag);
    out.extend_from_slice(&payload_len.to_le_bytes());
    // Move payload bytes in place (same pattern as MultiResultWriter).
    out.append(&mut payload);
    Ok(out)
}

fn frame_item_from_slice(tag: u8, payload: &[u8]) -> Result<Vec<u8>> {
    let payload_len: u32 = payload.len().try_into().map_err(|_| {
        OdbcError::ResourceLimitReached(format!(
            "multi-result stream item payload exceeds u32: {}",
            payload.len()
        ))
    })?;
    let capacity = payload
        .len()
        .checked_add(5)
        .ok_or_else(|| OdbcError::ResourceLimitReached("stream item size overflow".to_string()))?;
    let mut out = Vec::with_capacity(capacity);
    out.push(tag);
    out.extend_from_slice(&payload_len.to_le_bytes());
    out.extend_from_slice(payload);
    Ok(out)
}

/// Spawn a worker that streams a multi-result batch via `BatchedStreamingState`.
/// Each emitted batch contains exactly one frame-encoded multi-result item;
/// the consumer assembles items by reading `[tag: u8][len: u32][payload]`
/// frames out of the chunk stream.
pub fn start_multi_batched_stream(
    handles: SharedHandleManager,
    conn_id: u32,
    sql: String,
    chunk_size: usize,
    fetch_size: usize,
    result_encoding: ResultEncoding,
) -> Result<BatchedStreamingState> {
    spawn_multi_stream_worker(
        handles,
        conn_id,
        sql,
        MultiStreamJob {
            chunk_size,
            fetch_size,
            result_encoding,
            is_async: false,
            param_bytes: None,
        },
    )
    .map(|either| match either {
        EitherStream::Batched(b) => b,
        EitherStream::Async(_) => unreachable!(),
    })
}

pub fn start_multi_batched_stream_with_params(
    handles: SharedHandleManager,
    conn_id: u32,
    sql: String,
    chunk_size: usize,
    fetch_size: usize,
    result_encoding: ResultEncoding,
    params: Vec<u8>,
) -> Result<BatchedStreamingState> {
    spawn_multi_stream_worker(
        handles,
        conn_id,
        sql,
        MultiStreamJob {
            chunk_size,
            fetch_size,
            result_encoding,
            is_async: false,
            param_bytes: Some(params),
        },
    )
    .map(|either| match either {
        EitherStream::Batched(b) => b,
        EitherStream::Async(_) => unreachable!(),
    })
}

/// Like [`start_multi_batched_stream`] but returns an `AsyncStreamingState`
/// so callers can poll for readiness without blocking on `recv()`.
pub fn start_multi_async_stream(
    handles: SharedHandleManager,
    conn_id: u32,
    sql: String,
    chunk_size: usize,
    fetch_size: usize,
    result_encoding: ResultEncoding,
) -> Result<AsyncStreamingState> {
    spawn_multi_stream_worker(
        handles,
        conn_id,
        sql,
        MultiStreamJob {
            chunk_size,
            fetch_size,
            result_encoding,
            is_async: true,
            param_bytes: None,
        },
    )
    .map(|either| match either {
        EitherStream::Batched(_) => unreachable!(),
        EitherStream::Async(a) => a,
    })
}

pub fn start_multi_async_stream_with_params(
    handles: SharedHandleManager,
    conn_id: u32,
    sql: String,
    chunk_size: usize,
    fetch_size: usize,
    result_encoding: ResultEncoding,
    params: Vec<u8>,
) -> Result<AsyncStreamingState> {
    spawn_multi_stream_worker(
        handles,
        conn_id,
        sql,
        MultiStreamJob {
            chunk_size,
            fetch_size,
            result_encoding,
            is_async: true,
            param_bytes: Some(params),
        },
    )
    .map(|either| match either {
        EitherStream::Batched(_) => unreachable!(),
        EitherStream::Async(a) => a,
    })
}

/// Pooled-connection variant of [`start_multi_batched_stream`].
pub fn start_multi_batched_stream_pooled(
    pooled: SharedPooledConnection,
    sql: String,
    chunk_size: usize,
    fetch_size: usize,
    result_encoding: ResultEncoding,
    on_complete: Option<Box<dyn FnOnce() + Send + 'static>>,
) -> Result<BatchedStreamingState> {
    spawn_multi_stream_worker_pooled(
        pooled,
        sql,
        on_complete,
        MultiStreamJob {
            chunk_size,
            fetch_size,
            result_encoding,
            is_async: false,
            param_bytes: None,
        },
    )
    .map(|either| match either {
        EitherStream::Batched(b) => b,
        EitherStream::Async(_) => unreachable!(),
    })
}

pub fn start_multi_batched_stream_pooled_with_params(
    pooled: SharedPooledConnection,
    sql: String,
    chunk_size: usize,
    fetch_size: usize,
    result_encoding: ResultEncoding,
    on_complete: Option<Box<dyn FnOnce() + Send + 'static>>,
    params: Vec<u8>,
) -> Result<BatchedStreamingState> {
    spawn_multi_stream_worker_pooled(
        pooled,
        sql,
        on_complete,
        MultiStreamJob {
            chunk_size,
            fetch_size,
            result_encoding,
            is_async: false,
            param_bytes: Some(params),
        },
    )
    .map(|either| match either {
        EitherStream::Batched(b) => b,
        EitherStream::Async(_) => unreachable!(),
    })
}

/// Pooled-connection variant of [`start_multi_async_stream`].
pub fn start_multi_async_stream_pooled(
    pooled: SharedPooledConnection,
    sql: String,
    chunk_size: usize,
    fetch_size: usize,
    result_encoding: ResultEncoding,
    on_complete: Option<Box<dyn FnOnce() + Send + 'static>>,
) -> Result<AsyncStreamingState> {
    spawn_multi_stream_worker_pooled(
        pooled,
        sql,
        on_complete,
        MultiStreamJob {
            chunk_size,
            fetch_size,
            result_encoding,
            is_async: true,
            param_bytes: None,
        },
    )
    .map(|either| match either {
        EitherStream::Batched(_) => unreachable!(),
        EitherStream::Async(a) => a,
    })
}

pub fn start_multi_async_stream_pooled_with_params(
    pooled: SharedPooledConnection,
    sql: String,
    chunk_size: usize,
    fetch_size: usize,
    result_encoding: ResultEncoding,
    on_complete: Option<Box<dyn FnOnce() + Send + 'static>>,
    params: Vec<u8>,
) -> Result<AsyncStreamingState> {
    spawn_multi_stream_worker_pooled(
        pooled,
        sql,
        on_complete,
        MultiStreamJob {
            chunk_size,
            fetch_size,
            result_encoding,
            is_async: true,
            param_bytes: Some(params),
        },
    )
    .map(|either| match either {
        EitherStream::Batched(_) => unreachable!(),
        EitherStream::Async(a) => a,
    })
}

enum EitherStream {
    Batched(BatchedStreamingState),
    Async(AsyncStreamingState),
}

struct MultiStreamJob {
    chunk_size: usize,
    fetch_size: usize,
    result_encoding: ResultEncoding,
    is_async: bool,
    param_bytes: Option<Vec<u8>>,
}

fn spawn_multi_stream_worker(
    handles: SharedHandleManager,
    conn_id: u32,
    sql: String,
    job: MultiStreamJob,
) -> Result<EitherStream> {
    let MultiStreamJob {
        chunk_size,
        fetch_size,
        result_encoding,
        is_async,
        param_bytes,
    } = job;
    let chunk_size = chunk_size.max(1);
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(MULTI_STREAM_CHANNEL_DEPTH);
    let cancel_requested = Arc::new(AtomicBool::new(false));
    let buffer_pool = Arc::new(BatchBufferPool::default());

    let conn_arc = {
        let Ok(guard) = handles.lock() else {
            return Err(OdbcError::InternalError(
                "Failed to lock HandleManager".to_string(),
            ));
        };
        guard
            .get_connection(conn_id)
            .map_err(|e| OdbcError::InternalError(format!("Invalid connection: {}", e)))?
    };

    let join = std::thread::spawn({
        let cancel = Arc::clone(&cancel_requested);
        let worker_pool = Arc::clone(&buffer_pool);
        move || {
            #[allow(unused_mut)]
            let Ok(mut conn_guard) = conn_arc.lock() else {
                let _ = tx.send(BatchedMessage::Error(
                    "Failed to lock connection".to_string(),
                ));
                return;
            };
            let mut on_item = |framed: Vec<u8>| -> Result<()> {
                tx.send(BatchedMessage::Batch(framed))
                    .map_err(|e| OdbcError::InternalError(e.to_string()))
            };
            #[cfg(feature = "statement-handle-reuse")]
            let result = conn_guard.with_multi_prepared_mut(&sql, |stmt| {
                drive_prepared_multi_result_stream(
                    stmt,
                    fetch_size,
                    result_encoding,
                    &mut on_item,
                    Some(cancel),
                    Some(worker_pool.as_ref()),
                    param_bytes.as_deref(),
                )
            });
            #[cfg(not(feature = "statement-handle-reuse"))]
            let result = conn_guard.checked_connection().and_then(|conn| {
                drive_multi_result_stream(
                    conn,
                    &sql,
                    fetch_size,
                    result_encoding,
                    &mut on_item,
                    Some(cancel),
                    Some(worker_pool.as_ref()),
                    param_bytes.as_deref(),
                )
            });
            match result {
                Ok(()) => {
                    if tx.send(BatchedMessage::Done).is_err() {
                        #[cfg(feature = "statement-handle-reuse")]
                        conn_guard.invalidate_prepared(&sql);
                    }
                }
                Err(OdbcError::Cancelled) => {
                    let _ = tx.send(BatchedMessage::Cancelled);
                }
                Err(e) => {
                    let _ = tx.send(BatchedMessage::Error(e.to_string()));
                }
            }
        }
    });

    if is_async {
        Ok(EitherStream::Async(
            AsyncStreamingState::new(rx, chunk_size, cancel_requested, Some(join))
                .with_buffer_pool(buffer_pool),
        ))
    } else {
        Ok(EitherStream::Batched(
            BatchedStreamingState::new(rx, chunk_size, cancel_requested, Some(join))
                .with_buffer_pool(buffer_pool),
        ))
    }
}

fn spawn_multi_stream_worker_pooled(
    pooled: SharedPooledConnection,
    sql: String,
    on_complete: Option<Box<dyn FnOnce() + Send + 'static>>,
    job: MultiStreamJob,
) -> Result<EitherStream> {
    let MultiStreamJob {
        chunk_size,
        fetch_size,
        result_encoding,
        is_async,
        param_bytes,
    } = job;
    let chunk_size = chunk_size.max(1);
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(MULTI_STREAM_CHANNEL_DEPTH);
    let cancel_requested = Arc::new(AtomicBool::new(false));
    let buffer_pool = Arc::new(BatchBufferPool::default());

    let join = std::thread::spawn({
        let cancel = Arc::clone(&cancel_requested);
        let worker_pool = Arc::clone(&buffer_pool);
        move || {
            let _completion = WorkerCompletion::new(on_complete);
            #[allow(unused_mut)]
            let Ok(mut conn_guard) = pooled.lock() else {
                let _ = tx.send(BatchedMessage::Error(
                    "Failed to lock pooled connection".to_string(),
                ));
                return;
            };
            let mut on_item = |framed: Vec<u8>| -> Result<()> {
                tx.send(BatchedMessage::Batch(framed))
                    .map_err(|e| OdbcError::InternalError(e.to_string()))
            };
            #[cfg(feature = "statement-handle-reuse")]
            let result = conn_guard
                .cached_mut()
                .with_multi_prepared_mut(&sql, |stmt| {
                    drive_prepared_multi_result_stream(
                        stmt,
                        fetch_size,
                        result_encoding,
                        &mut on_item,
                        Some(cancel),
                        Some(worker_pool.as_ref()),
                        param_bytes.as_deref(),
                    )
                });
            #[cfg(not(feature = "statement-handle-reuse"))]
            let result = conn_guard.checked_connection().and_then(|conn| {
                drive_multi_result_stream(
                    conn,
                    &sql,
                    fetch_size,
                    result_encoding,
                    &mut on_item,
                    Some(cancel),
                    Some(worker_pool.as_ref()),
                    param_bytes.as_deref(),
                )
            });
            match result {
                Ok(()) => {
                    if tx.send(BatchedMessage::Done).is_err() {
                        #[cfg(feature = "statement-handle-reuse")]
                        conn_guard.cached_mut().invalidate_prepared(&sql);
                    }
                }
                Err(OdbcError::Cancelled) => {
                    let _ = tx.send(BatchedMessage::Cancelled);
                }
                Err(e) => {
                    let _ = tx.send(BatchedMessage::Error(e.to_string()));
                }
            }
        }
    });

    if is_async {
        Ok(EitherStream::Async(
            AsyncStreamingState::new(rx, chunk_size, cancel_requested, Some(join))
                .with_buffer_pool(buffer_pool),
        ))
    } else {
        Ok(EitherStream::Batched(
            BatchedStreamingState::new(rx, chunk_size, cancel_requested, Some(join))
                .with_buffer_pool(buffer_pool),
        ))
    }
}

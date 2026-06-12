use super::columns::{describe_streaming_columns, encode_row_buffer_with_encoding};
use super::state::{AsyncStreamingState, BatchedMessage, BatchedStreamingState, WorkerCompletion};
use crate::engine::query::ResultEncoding;
use crate::error::{OdbcError, Result};
use crate::handles::SharedHandleManager;
use crate::pool::SharedPooledConnection;
use crate::protocol::RowBuffer;
use odbc_api::handles::{AsStatementRef, SqlResult, Statement};
use odbc_api::{Connection, Cursor, CursorImpl, ResultSetMetadata};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;

/// Item-frame tags for the streaming multi-result wire format (M8).
pub const MULTI_STREAM_ITEM_TAG_RESULT_SET: u8 = 0;
pub const MULTI_STREAM_ITEM_TAG_ROW_COUNT: u8 = 1;
/// Continuation batch for the current result set (v4.2 batched per cursor).
pub const MULTI_STREAM_ITEM_TAG_RESULT_SET_BATCH: u8 = 2;

/// Default ODBC rows per batch when streaming multi-result cursors.
pub(crate) const DEFAULT_MULTI_STREAM_FETCH_SIZE: usize = 100;

/// Drive a prepared statement that may yield multiple result sets and call
/// `on_item` for **every** result set or row-count, in order. Each item is
/// wire-framed as `[tag: u8][len: u32 LE][payload]`. Used by the streaming
/// FFIs to surface items lazily instead of materialising the whole batch.
///
/// Mirrors `ExecutionEngine::collect_multi_results` (see M1 fix in v3.2.0)
/// but pushes each item through a callback instead of accumulating them.
fn drive_multi_result_stream<F>(
    conn: &Connection<'static>,
    sql: &str,
    fetch_size: usize,
    result_encoding: ResultEncoding,
    on_item: &mut F,
    cancel_requested: Option<Arc<AtomicBool>>,
) -> Result<()>
where
    F: FnMut(Vec<u8>) -> Result<()>,
{
    let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;
    let cancel_check = || {
        cancel_requested
            .as_ref()
            .is_some_and(|c| c.load(Ordering::Relaxed))
    };

    // Encode the initial result inside a scope that bounds the cursor's
    // borrow on `stmt`. Same SQLCloseCursor avoidance pattern as
    // `ExecutionEngine::execute_multi_result_inner` (M1 fix in v3.2.0).
    let had_initial_cursor = {
        let initial_cursor = stmt.execute(()).map_err(OdbcError::from)?;
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
            SqlResult::NoData => return Ok(()),
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
fn encode_cursor_batched<C, F>(
    mut cursor: C,
    fetch_size: usize,
    result_encoding: ResultEncoding,
    on_item: &mut F,
    cancel_check: impl Fn() -> bool,
) -> Result<C>
where
    C: Cursor + ResultSetMetadata,
    F: FnMut(Vec<u8>) -> Result<()>,
{
    let batch_size = fetch_size.max(1);
    let mut row_buffer = RowBuffer::new();
    let column_types = describe_streaming_columns(&mut cursor, &mut row_buffer)?;
    let mut first_batch = true;

    loop {
        if cancel_check() {
            return Err(OdbcError::Cancelled);
        }

        row_buffer.rows.clear();
        let _fetched = crate::engine::fetch::fetch_batch_into_row_buffer(
            &mut cursor,
            &column_types,
            batch_size,
            &mut row_buffer,
        )?;

        if row_buffer.row_count() == 0 {
            if first_batch {
                let encoded = encode_row_buffer_with_encoding(&row_buffer, result_encoding)?;
                on_item(frame_item(MULTI_STREAM_ITEM_TAG_RESULT_SET, encoded)?)?;
            }
            break;
        }

        let tag = if first_batch {
            MULTI_STREAM_ITEM_TAG_RESULT_SET
        } else {
            MULTI_STREAM_ITEM_TAG_RESULT_SET_BATCH
        };
        let encoded = encode_row_buffer_with_encoding(&row_buffer, result_encoding)?;
        on_item(frame_item(tag, encoded)?)?;
        first_batch = false;
    }

    Ok(cursor)
}

pub(crate) fn frame_item(tag: u8, payload: Vec<u8>) -> Result<Vec<u8>> {
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
    out.extend(payload);
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
) -> Result<BatchedStreamingState> {
    spawn_multi_stream_worker(handles, conn_id, sql, chunk_size, /* async = */ false).map(
        |either| match either {
            EitherStream::Batched(b) => b,
            EitherStream::Async(_) => unreachable!(),
        },
    )
}

/// Like [`start_multi_batched_stream`] but returns an `AsyncStreamingState`
/// so callers can poll for readiness without blocking on `recv()`.
pub fn start_multi_async_stream(
    handles: SharedHandleManager,
    conn_id: u32,
    sql: String,
    chunk_size: usize,
) -> Result<AsyncStreamingState> {
    spawn_multi_stream_worker(handles, conn_id, sql, chunk_size, /* async = */ true).map(|either| {
        match either {
            EitherStream::Batched(_) => unreachable!(),
            EitherStream::Async(a) => a,
        }
    })
}

/// Pooled-connection variant of [`start_multi_batched_stream`].
pub fn start_multi_batched_stream_pooled(
    pooled: SharedPooledConnection,
    sql: String,
    chunk_size: usize,
    on_complete: Option<Box<dyn FnOnce() + Send + 'static>>,
) -> Result<BatchedStreamingState> {
    spawn_multi_stream_worker_pooled(
        pooled,
        sql,
        chunk_size,
        /* async = */ false,
        on_complete,
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
    on_complete: Option<Box<dyn FnOnce() + Send + 'static>>,
) -> Result<AsyncStreamingState> {
    spawn_multi_stream_worker_pooled(
        pooled,
        sql,
        chunk_size,
        /* async = */ true,
        on_complete,
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

fn spawn_multi_stream_worker(
    handles: SharedHandleManager,
    conn_id: u32,
    sql: String,
    chunk_size: usize,
    is_async: bool,
) -> Result<EitherStream> {
    let chunk_size = chunk_size.max(1);
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let cancel_requested = Arc::new(AtomicBool::new(false));

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
        move || {
            let Ok(conn_guard) = conn_arc.lock() else {
                let _ = tx.send(BatchedMessage::Error(
                    "Failed to lock connection".to_string(),
                ));
                return;
            };
            let mut on_item = |framed: Vec<u8>| -> Result<()> {
                tx.send(BatchedMessage::Batch(framed))
                    .map_err(|e| OdbcError::InternalError(e.to_string()))
            };
            match drive_multi_result_stream(
                conn_guard.connection(),
                &sql,
                DEFAULT_MULTI_STREAM_FETCH_SIZE,
                ResultEncoding::RowMajor,
                &mut on_item,
                Some(cancel),
            ) {
                Ok(()) => {
                    let _ = tx.send(BatchedMessage::Done);
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
        Ok(EitherStream::Async(AsyncStreamingState::new(
            rx,
            chunk_size,
            cancel_requested,
            Some(join),
        )))
    } else {
        Ok(EitherStream::Batched(BatchedStreamingState::new(
            rx,
            chunk_size,
            cancel_requested,
            Some(join),
        )))
    }
}

fn spawn_multi_stream_worker_pooled(
    pooled: SharedPooledConnection,
    sql: String,
    chunk_size: usize,
    is_async: bool,
    on_complete: Option<Box<dyn FnOnce() + Send + 'static>>,
) -> Result<EitherStream> {
    let chunk_size = chunk_size.max(1);
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let cancel_requested = Arc::new(AtomicBool::new(false));

    let join = std::thread::spawn({
        let cancel = Arc::clone(&cancel_requested);
        move || {
            let _completion = WorkerCompletion::new(on_complete);
            let Ok(conn_guard) = pooled.lock() else {
                let _ = tx.send(BatchedMessage::Error(
                    "Failed to lock pooled connection".to_string(),
                ));
                return;
            };
            let mut on_item = |framed: Vec<u8>| -> Result<()> {
                tx.send(BatchedMessage::Batch(framed))
                    .map_err(|e| OdbcError::InternalError(e.to_string()))
            };
            match drive_multi_result_stream(
                conn_guard.get_connection(),
                &sql,
                DEFAULT_MULTI_STREAM_FETCH_SIZE,
                ResultEncoding::RowMajor,
                &mut on_item,
                Some(cancel),
            ) {
                Ok(()) => {
                    let _ = tx.send(BatchedMessage::Done);
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
        Ok(EitherStream::Async(AsyncStreamingState::new(
            rx,
            chunk_size,
            cancel_requested,
            Some(join),
        )))
    } else {
        Ok(EitherStream::Batched(BatchedStreamingState::new(
            rx,
            chunk_size,
            cancel_requested,
            Some(join),
        )))
    }
}

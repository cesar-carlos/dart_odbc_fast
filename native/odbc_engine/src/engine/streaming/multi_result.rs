use super::columns::encode_row_buffer;
use super::state::{AsyncStreamingState, BatchedMessage, BatchedStreamingState, WorkerCompletion};
use crate::engine::cell_reader::CellReader;
use crate::engine::sqlserver_json::coalesce_for_json_rows;
use crate::error::{OdbcError, Result};
use crate::handles::SharedHandleManager;
use crate::pool::SharedPooledConnection;
use crate::protocol::{OdbcType, RowBuffer};
use odbc_api::handles::{AsStatementRef, SqlResult, Statement};
use odbc_api::{Connection, Cursor, CursorImpl, ResultSetMetadata};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;

/// Item-frame tags for the streaming multi-result wire format (M8).
pub const MULTI_STREAM_ITEM_TAG_RESULT_SET: u8 = 0;
pub const MULTI_STREAM_ITEM_TAG_ROW_COUNT: u8 = 1;

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
        if let Some(mut cursor) = initial_cursor {
            if cancel_check() {
                return Err(OdbcError::Cancelled);
            }
            let encoded = encode_cursor_to_buffer(&mut cursor)?;
            on_item(frame_item(MULTI_STREAM_ITEM_TAG_RESULT_SET, encoded)?)?;
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
            let mut cursor = unsafe { CursorImpl::new(stmt.as_stmt_ref()) };
            let encoded = encode_cursor_to_buffer(&mut cursor)?;
            on_item(frame_item(MULTI_STREAM_ITEM_TAG_RESULT_SET, encoded)?)?;
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

/// Read every row from `cursor` into a `RowBuffer` and encode it via
/// `RowBufferEncoder` (binary protocol v1). Local helper to avoid coupling
/// `StreamingExecutor` with `ExecutionEngine`.
fn encode_cursor_to_buffer<C>(cursor: &mut C) -> Result<Vec<u8>>
where
    C: Cursor + ResultSetMetadata,
{
    let mut row_buffer = RowBuffer::new();
    let cols_i16 = cursor.num_result_cols().map_err(OdbcError::from)?;
    let cols_u16: u16 = cols_i16
        .try_into()
        .map_err(|_| OdbcError::InternalError("Invalid column count".to_string()))?;
    let cols_usize: usize = cols_u16.into();
    let mut column_types: Vec<OdbcType> = Vec::with_capacity(cols_usize);

    for col_idx in 1..=cols_u16 {
        let col_name = cursor.col_name(col_idx).map_err(OdbcError::from)?;
        let col_type = cursor.col_data_type(col_idx).map_err(OdbcError::from)?;
        let sql_type_code = OdbcType::sql_type_code_from_data_type(&col_type);
        let odbc_type = OdbcType::from_odbc_sql_type(sql_type_code);
        row_buffer.add_column(col_name.to_string(), odbc_type);
        column_types.push(odbc_type);
    }

    let mut cell_reader = CellReader::new();
    while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
        let mut row_data = Vec::with_capacity(column_types.len());
        for (col_idx, &odbc_type) in column_types.iter().enumerate() {
            let col_number: u16 = (col_idx + 1)
                .try_into()
                .map_err(|_| OdbcError::InternalError("Invalid column number".to_string()))?;
            let cell_data = cell_reader.read_cell_bytes(&mut row, col_number, odbc_type)?;
            row_data.push(cell_data);
        }
        row_buffer.add_row(row_data);
    }

    // FOR JSON normalisation — multi-result item is fully materialised
    // before framing, so the same coalescing applies here (closes #2).
    coalesce_for_json_rows(&mut row_buffer);

    encode_row_buffer(&row_buffer)
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

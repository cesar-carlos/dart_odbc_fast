use super::columns::{describe_streaming_columns, encode_row_buffer};
use super::state::{
    AsyncStreamingState, BatchedMessage, BatchedStreamingState, StreamState, StreamingState,
    StreamingStateFileBacked, WorkerCompletion,
};
use crate::engine::core::{DiskSpillStream, DiskSpillWriter};
use crate::engine::sqlserver_json::coalesce_for_json_rows;
use crate::error::{OdbcError, Result};
use crate::handles::SharedHandleManager;
use crate::pool::SharedPooledConnection;
use crate::protocol::{RowBuffer, RowBufferEncoder};
use odbc_api::Connection;
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
pub struct StreamingExecutor {
    chunk_size: usize,
}

impl StreamingExecutor {
    pub fn new(chunk_size: usize) -> Self {
        Self { chunk_size }
    }

    #[cfg(test)]
    pub(crate) fn chunk_size(&self) -> usize {
        self.chunk_size
    }

    /// Drains the full cursor into one encoded protocol message for legacy
    /// buffer-mode FFI (`odbc_stream_start`). Applies FOR JSON coalescing.
    ///
    /// Prefer [`Self::execute_streaming_batched`] or [`Self::start_batched_stream`]
    /// for bounded-memory cursor streaming.
    fn materialize_cursor_to_encoded(conn: &Connection<'static>, sql: &str) -> Result<Vec<u8>> {
        let mut row_buffer = RowBuffer::new();
        let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;
        let cursor = stmt.execute(()).map_err(OdbcError::from)?;
        let Some(mut cursor) = cursor else {
            return Err(OdbcError::InternalError("No data returned".to_string()));
        };
        let column_types = describe_streaming_columns(&mut cursor, &mut row_buffer)?;
        let _cursor = crate::engine::fetch::fetch_cursor_into_row_buffer(
            cursor,
            &column_types,
            &mut row_buffer,
        )?;
        // FOR JSON normalisation — buffer-mode materialises the full result
        // before encoding, so coalescing is safe here. See `engine::sqlserver_json`.
        coalesce_for_json_rows(&mut row_buffer);
        encode_row_buffer(&row_buffer)
    }

    /// Legacy buffer-mode streaming: materialises the full result set before
    /// byte-level FFI chunking via [`StreamingState`].
    ///
    /// **Prefer batched streaming.** [`Self::execute_streaming_batched`] and
    /// `odbc_stream_start_batched` keep memory bounded to one fetch batch.
    /// This path remains for `odbc_stream_start` compatibility only.
    pub fn execute_streaming(
        &self,
        conn: &Connection<'static>,
        sql: &str,
    ) -> Result<StreamingState> {
        let encoded = Self::materialize_cursor_to_encoded(conn, sql)?;
        Ok(StreamingState {
            data: encoded,
            offset: 0,
            chunk_size: self.chunk_size,
        })
    }

    /// Buffer-mode streaming with optional spill-to-disk. When `spill_threshold_mb > 0`,
    /// encodes to `DiskSpillStream`; if data exceeds threshold, spills to temp file
    /// and returns `StreamState::FileBacked` for chunked read without loading full result.
    ///
    /// Like [`Self::execute_streaming`], this still materialises the full cursor
    /// before encoding. Prefer batched streaming for large result sets.
    pub fn execute_streaming_with_spill(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        spill_threshold_mb: Option<usize>,
    ) -> Result<StreamState> {
        let mut row_buffer = RowBuffer::new();
        let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;
        let cursor = stmt.execute(()).map_err(OdbcError::from)?;
        let Some(mut cursor) = cursor else {
            return Err(OdbcError::InternalError("No data returned".to_string()));
        };
        let column_types = describe_streaming_columns(&mut cursor, &mut row_buffer)?;
        let _cursor = crate::engine::fetch::fetch_cursor_into_row_buffer(
            cursor,
            &column_types,
            &mut row_buffer,
        )?;
        coalesce_for_json_rows(&mut row_buffer);

        let chunk_size = self.chunk_size;

        if let Some(threshold_mb) = spill_threshold_mb.filter(|&t| t > 0) {
            let mut spill = DiskSpillStream::new(threshold_mb);
            let mut writer = DiskSpillWriter::new(&mut spill);
            RowBufferEncoder::encode_to_writer_result(&row_buffer, &mut writer)?;
            writer
                .flush()
                .map_err(|e| OdbcError::InternalError(format!("spill flush: {}", e)))?;

            match spill.finish_for_streaming_read()? {
                crate::engine::core::SpillReadSource::File(path) => {
                    let total_len = std::fs::metadata(&path)
                        .map(|m| m.len() as usize)
                        .unwrap_or(0);
                    Ok(StreamState::FileBacked(StreamingStateFileBacked::new(
                        path, chunk_size, total_len,
                    )?))
                }
                crate::engine::core::SpillReadSource::Memory(data) => {
                    Ok(StreamState::InMemory(StreamingState {
                        data,
                        offset: 0,
                        chunk_size,
                    }))
                }
            }
        } else {
            let encoded = encode_row_buffer(&row_buffer)?;
            Ok(StreamState::InMemory(StreamingState {
                data: encoded,
                offset: 0,
                chunk_size,
            }))
        }
    }

    /// True cursor-based streaming: fetches up to `fetch_size` rows per batch,
    /// invokes `on_batch` for each encoded batch. Memory footprint is bounded
    /// by one batch instead of the full result set.
    ///
    /// **FOR JSON note**: this path deliberately does **not** call
    /// `coalesce_for_json_rows` because chunks would be split across batches
    /// and joining them would require materialising the full payload —
    /// which defeats the point of batched streaming. Callers consuming
    /// `FOR JSON` output through this API are responsible for concatenating
    /// the per-batch single-column rows themselves, or for switching to
    /// [`StreamingExecutor::execute_streaming`] / [`execute_streaming_with_spill`]
    /// where coalescing is applied automatically.
    pub fn execute_streaming_batched<F>(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        fetch_size: usize,
        mut on_batch: F,
        cancel_requested: Option<Arc<AtomicBool>>,
    ) -> Result<()>
    where
        F: FnMut(Vec<u8>) -> Result<()>,
    {
        let batch_size = fetch_size.max(1);
        let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;
        let cursor = stmt.execute(()).map_err(OdbcError::from)?;

        let mut cursor = match cursor {
            Some(c) => c,
            None => return Ok(()),
        };

        let mut row_buffer = RowBuffer::new();
        let column_types = describe_streaming_columns(&mut cursor, &mut row_buffer)?;

        let mut first_batch = true;
        loop {
            if cancel_requested
                .as_ref()
                .is_some_and(|c| c.load(Ordering::Relaxed))
            {
                return Err(OdbcError::InternalError("Stream cancelled".to_string()));
            }

            row_buffer.rows.clear();
            crate::engine::fetch::fetch_batch_into_row_buffer(
                &mut cursor,
                &column_types,
                batch_size,
                &mut row_buffer,
            )?;

            if row_buffer.row_count() == 0 {
                if first_batch {
                    let encoded = encode_row_buffer(&row_buffer)?;
                    on_batch(encoded)?;
                }
                break;
            }

            let encoded = encode_row_buffer(&row_buffer)?;
            on_batch(encoded)?;
            first_batch = false;
        }

        Ok(())
    }

    /// Starts cursor-based batched streaming via a worker thread. Uses
    /// `execute_streaming_batched` internally; memory is bounded to one batch.
    /// Returns state that yields chunks on `fetch_next_chunk` until done.
    /// The HandleManager lock is held only briefly to clone the connection;
    /// the per-connection lock is held for the stream duration.
    pub fn start_batched_stream(
        &self,
        handles: SharedHandleManager,
        conn_id: u32,
        sql: String,
        fetch_size: usize,
        chunk_size: usize,
    ) -> Result<BatchedStreamingState> {
        let fetch_size = fetch_size.max(1);
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

        let cancel = Arc::clone(&cancel_requested);
        let join = std::thread::spawn(move || {
            let Ok(conn_guard) = conn_arc.lock() else {
                let _ = tx.send(BatchedMessage::Error(
                    "Failed to lock connection".to_string(),
                ));
                return;
            };
            let executor = StreamingExecutor::new(chunk_size);
            match executor.execute_streaming_batched(
                conn_guard.connection(),
                &sql,
                fetch_size,
                |batch| {
                    tx.send(BatchedMessage::Batch(batch))
                        .map_err(|e| OdbcError::InternalError(e.to_string()))
                },
                Some(cancel),
            ) {
                Ok(()) => {
                    let _ = tx.send(BatchedMessage::Done);
                }
                Err(e) => {
                    let msg = e.to_string();
                    let _ = tx.send(if msg.contains("cancelled") {
                        BatchedMessage::Cancelled
                    } else {
                        BatchedMessage::Error(msg)
                    });
                }
            }
        });

        Ok(BatchedStreamingState::new(
            rx,
            chunk_size,
            cancel_requested,
            Some(join),
        ))
    }

    /// Starts async cursor-based streaming with explicit poll support.
    /// The fetch worker runs in background and pushes encoded batches into
    /// an internal channel. Consumers can call `poll_status` to decide when
    /// `fetch_next_chunk` is likely to return data.
    pub fn start_async_stream(
        &self,
        handles: SharedHandleManager,
        conn_id: u32,
        sql: String,
        fetch_size: usize,
        chunk_size: usize,
    ) -> Result<AsyncStreamingState> {
        let fetch_size = fetch_size.max(1);
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

        let cancel = Arc::clone(&cancel_requested);
        let join = std::thread::spawn(move || {
            let Ok(conn_guard) = conn_arc.lock() else {
                let _ = tx.send(BatchedMessage::Error(
                    "Failed to lock connection".to_string(),
                ));
                return;
            };
            let executor = StreamingExecutor::new(chunk_size);
            match executor.execute_streaming_batched(
                conn_guard.connection(),
                &sql,
                fetch_size,
                |batch| {
                    tx.send(BatchedMessage::Batch(batch))
                        .map_err(|e| OdbcError::InternalError(e.to_string()))
                },
                Some(cancel),
            ) {
                Ok(()) => {
                    let _ = tx.send(BatchedMessage::Done);
                }
                Err(e) => {
                    let msg = e.to_string();
                    let _ = tx.send(if msg.contains("cancelled") {
                        BatchedMessage::Cancelled
                    } else {
                        BatchedMessage::Error(msg)
                    });
                }
            }
        });

        Ok(AsyncStreamingState::new(
            rx,
            chunk_size,
            cancel_requested,
            Some(join),
        ))
    }

    /// Pooled-connection variant of [`Self::start_batched_stream`]. The
    /// supplied completion callback runs when the worker exits, allowing the
    /// FFI layer to release long-lived pool busy accounting after the ODBC
    /// connection is no longer in use.
    pub fn start_batched_stream_pooled(
        &self,
        pooled: SharedPooledConnection,
        sql: String,
        fetch_size: usize,
        chunk_size: usize,
        on_complete: Option<Box<dyn FnOnce() + Send + 'static>>,
    ) -> Result<BatchedStreamingState> {
        let fetch_size = fetch_size.max(1);
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
                let executor = StreamingExecutor::new(chunk_size);
                match executor.execute_streaming_batched(
                    conn_guard.get_connection(),
                    &sql,
                    fetch_size,
                    |batch| {
                        tx.send(BatchedMessage::Batch(batch))
                            .map_err(|e| OdbcError::InternalError(e.to_string()))
                    },
                    Some(cancel),
                ) {
                    Ok(()) => {
                        let _ = tx.send(BatchedMessage::Done);
                    }
                    Err(e) => {
                        let msg = e.to_string();
                        let _ = tx.send(if msg.contains("cancelled") {
                            BatchedMessage::Cancelled
                        } else {
                            BatchedMessage::Error(msg)
                        });
                    }
                }
            }
        });

        Ok(BatchedStreamingState::new(
            rx,
            chunk_size,
            cancel_requested,
            Some(join),
        ))
    }

    /// Pooled-connection variant of [`Self::start_async_stream`].
    pub fn start_async_stream_pooled(
        &self,
        pooled: SharedPooledConnection,
        sql: String,
        fetch_size: usize,
        chunk_size: usize,
        on_complete: Option<Box<dyn FnOnce() + Send + 'static>>,
    ) -> Result<AsyncStreamingState> {
        let fetch_size = fetch_size.max(1);
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
                let executor = StreamingExecutor::new(chunk_size);
                match executor.execute_streaming_batched(
                    conn_guard.get_connection(),
                    &sql,
                    fetch_size,
                    |batch| {
                        tx.send(BatchedMessage::Batch(batch))
                            .map_err(|e| OdbcError::InternalError(e.to_string()))
                    },
                    Some(cancel),
                ) {
                    Ok(()) => {
                        let _ = tx.send(BatchedMessage::Done);
                    }
                    Err(e) => {
                        let msg = e.to_string();
                        let _ = tx.send(if msg.contains("cancelled") {
                            BatchedMessage::Cancelled
                        } else {
                            BatchedMessage::Error(msg)
                        });
                    }
                }
            }
        });

        Ok(AsyncStreamingState::new(
            rx,
            chunk_size,
            cancel_requested,
            Some(join),
        ))
    }
}

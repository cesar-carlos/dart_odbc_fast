use crate::engine::cell_reader::read_cell_bytes;
use crate::engine::core::{DiskSpillStream, DiskSpillWriter};
use crate::error::{OdbcError, Result};
use crate::handles::SharedHandleManager;
use crate::protocol::{OdbcType, RowBuffer, RowBufferEncoder};
use odbc_api::{Connection, Cursor, ResultSetMetadata};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::thread::JoinHandle;

pub struct StreamingExecutor {
    chunk_size: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AsyncStreamStatus {
    Pending,
    Ready,
    Done,
    Cancelled,
    Error,
}

impl StreamingExecutor {
    pub fn new(chunk_size: usize) -> Self {
        Self { chunk_size }
    }

    pub fn execute_streaming(
        &self,
        conn: &Connection<'static>,
        sql: &str,
    ) -> Result<StreamingState> {
        let mut row_buffer = RowBuffer::new();
        let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;

        let cursor = stmt.execute(()).map_err(OdbcError::from)?;

        if let Some(mut cursor) = cursor {
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

            while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
                let mut row_data = Vec::new();

                for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                    let col_number: u16 = (col_idx + 1).try_into().map_err(|_| {
                        OdbcError::InternalError("Invalid column number".to_string())
                    })?;

                    let cell_data = read_cell_bytes(&mut row, col_number, odbc_type)?;

                    row_data.push(cell_data);
                }

                row_buffer.add_row(row_data);
            }

            let encoded = RowBufferEncoder::encode(&row_buffer);
            Ok(StreamingState {
                data: encoded,
                offset: 0,
                chunk_size: self.chunk_size,
            })
        } else {
            Err(OdbcError::InternalError("No data returned".to_string()))
        }
    }

    /// Buffer-mode streaming with optional spill-to-disk. When `spill_threshold_mb > 0`,
    /// encodes to `DiskSpillStream`; if data exceeds threshold, spills to temp file
    /// and returns `StreamState::FileBacked` for chunked read without loading full result.
    pub fn execute_streaming_with_spill(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        spill_threshold_mb: Option<usize>,
    ) -> Result<StreamState> {
        let mut row_buffer = RowBuffer::new();
        let mut stmt = conn.prepare(sql).map_err(OdbcError::from)?;

        let cursor = stmt.execute(()).map_err(OdbcError::from)?;

        if let Some(mut cursor) = cursor {
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

            while let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? {
                let mut row_data = Vec::new();

                for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                    let col_number: u16 = (col_idx + 1).try_into().map_err(|_| {
                        OdbcError::InternalError("Invalid column number".to_string())
                    })?;

                    let cell_data = read_cell_bytes(&mut row, col_number, odbc_type)?;

                    row_data.push(cell_data);
                }

                row_buffer.add_row(row_data);
            }

            let chunk_size = self.chunk_size;

            if let Some(threshold_mb) = spill_threshold_mb.filter(|&t| t > 0) {
                let mut spill = DiskSpillStream::new(threshold_mb);
                let mut writer = DiskSpillWriter::new(&mut spill);
                RowBufferEncoder::encode_to_writer(&row_buffer, &mut writer)
                    .map_err(|e| OdbcError::InternalError(format!("encode to spill: {}", e)))?;
                writer
                    .flush()
                    .map_err(|e| OdbcError::InternalError(format!("spill flush: {}", e)))?;

                match spill.finish_for_streaming_read()? {
                    crate::engine::core::SpillReadSource::File(path) => {
                        let total_len = std::fs::metadata(&path)
                            .map(|m| m.len() as usize)
                            .unwrap_or(0);
                        Ok(StreamState::FileBacked(StreamingStateFileBacked {
                            path,
                            offset: 0,
                            chunk_size,
                            total_len,
                        }))
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
                let encoded = RowBufferEncoder::encode(&row_buffer);
                Ok(StreamState::InMemory(StreamingState {
                    data: encoded,
                    offset: 0,
                    chunk_size,
                }))
            }
        } else {
            Err(OdbcError::InternalError("No data returned".to_string()))
        }
    }

    /// True cursor-based streaming: fetches up to `fetch_size` rows per batch,
    /// invokes `on_batch` for each encoded batch. Memory footprint is bounded
    /// by one batch instead of the full result set.
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

        let cols_i16 = cursor.num_result_cols().map_err(OdbcError::from)?;
        let cols_u16: u16 = cols_i16
            .try_into()
            .map_err(|_| OdbcError::InternalError("Invalid column count".to_string()))?;
        let cols_usize: usize = cols_u16.into();
        let mut column_types: Vec<OdbcType> = Vec::with_capacity(cols_usize);
        let mut row_buffer = RowBuffer::new();

        for col_idx in 1..=cols_u16 {
            let col_name = cursor.col_name(col_idx).map_err(OdbcError::from)?;
            let col_type = cursor.col_data_type(col_idx).map_err(OdbcError::from)?;
            let sql_type_code = OdbcType::sql_type_code_from_data_type(&col_type);
            let odbc_type = OdbcType::from_odbc_sql_type(sql_type_code);
            row_buffer.add_column(col_name.to_string(), odbc_type);
            column_types.push(odbc_type);
        }

        let mut first_batch = true;
        loop {
            if cancel_requested
                .as_ref()
                .is_some_and(|c| c.load(Ordering::Relaxed))
            {
                return Err(OdbcError::InternalError("Stream cancelled".to_string()));
            }

            row_buffer.rows.clear();
            let mut rows_fetched = 0;

            while rows_fetched < batch_size {
                let Some(mut row) = cursor.next_row().map_err(OdbcError::from)? else {
                    break;
                };
                let mut row_data = Vec::new();
                for (col_idx, &odbc_type) in column_types.iter().enumerate() {
                    let col_number: u16 = (col_idx + 1).try_into().map_err(|_| {
                        OdbcError::InternalError("Invalid column number".to_string())
                    })?;
                    let cell_data = read_cell_bytes(&mut row, col_number, odbc_type)?;
                    row_data.push(cell_data);
                }
                row_buffer.add_row(row_data);
                rows_fetched += 1;
            }

            if row_buffer.row_count() == 0 {
                if first_batch {
                    let encoded = RowBufferEncoder::encode(&row_buffer);
                    on_batch(encoded)?;
                }
                break;
            }

            let encoded = RowBufferEncoder::encode(&row_buffer);
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

        let join = std::thread::spawn({
            let sql = sql.clone();
            let cancel = Arc::clone(&cancel_requested);
            move || {
                let Ok(conn_guard) = conn_arc.lock() else {
                    let _ = tx.send(BatchedMessage::Error(
                        "Failed to lock connection".to_string(),
                    ));
                    return;
                };
                let executor = StreamingExecutor::new(chunk_size);
                match executor.execute_streaming_batched(
                    &conn_guard,
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

        Ok(BatchedStreamingState {
            receiver: rx,
            current_batch: None,
            offset: 0,
            chunk_size,
            done: false,
            stream_error: None,
            cancelled: false,
            cancel_requested,
            _join: Some(join),
        })
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

        let join = std::thread::spawn({
            let sql = sql.clone();
            let cancel = Arc::clone(&cancel_requested);
            move || {
                let Ok(conn_guard) = conn_arc.lock() else {
                    let _ = tx.send(BatchedMessage::Error(
                        "Failed to lock connection".to_string(),
                    ));
                    return;
                };
                let executor = StreamingExecutor::new(chunk_size);
                match executor.execute_streaming_batched(
                    &conn_guard,
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

        Ok(AsyncStreamingState {
            receiver: rx,
            current_batch: None,
            offset: 0,
            chunk_size,
            done: false,
            stream_error: None,
            cancelled: false,
            cancel_requested,
            _join: Some(join),
        })
    }
}

pub(crate) enum BatchedMessage {
    Batch(Vec<u8>),
    Done,
    Cancelled,
    Error(String),
}

pub struct BatchedStreamingState {
    receiver: mpsc::Receiver<BatchedMessage>,
    current_batch: Option<Vec<u8>>,
    offset: usize,
    chunk_size: usize,
    done: bool,
    stream_error: Option<String>,
    cancelled: bool,
    cancel_requested: Arc<AtomicBool>,
    _join: Option<JoinHandle<()>>,
}

impl BatchedStreamingState {
    /// Requests cancellation of the batched stream. The worker checks this flag
    /// between batches and exits early when set.
    pub fn request_cancel(&self) {
        self.cancel_requested.store(true, Ordering::Relaxed);
    }

    pub fn fetch_next_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        if let Some(ref msg) = self.stream_error {
            return Err(OdbcError::InternalError(msg.clone()));
        }
        if self.done {
            return Ok(None);
        }

        let batch_len = self.current_batch.as_ref().map(|b| b.len()).unwrap_or(0);
        if self.current_batch.is_none() || self.offset >= batch_len {
            match self.receiver.recv() {
                Ok(BatchedMessage::Batch(b)) => {
                    self.current_batch = Some(b);
                    self.offset = 0;
                }
                Ok(BatchedMessage::Done) => {
                    self.done = true;
                    return Ok(None);
                }
                Ok(BatchedMessage::Cancelled) => {
                    self.done = true;
                    self.cancelled = true;
                    return Ok(None);
                }
                Ok(BatchedMessage::Error(m)) => {
                    self.stream_error = Some(m.clone());
                    return Err(OdbcError::InternalError(m));
                }
                Err(_) => {
                    self.done = true;
                    return Ok(None);
                }
            }
        }

        let b = self.current_batch.as_ref().ok_or_else(|| {
            OdbcError::InternalError(
                "Streaming state corrupted: no batch available after receiver processing"
                    .to_string(),
            )
        })?;
        let end = (self.offset + self.chunk_size).min(b.len());
        let chunk = b[self.offset..end].to_vec();
        self.offset = end;

        Ok(Some(chunk))
    }

    pub fn has_more(&self) -> bool {
        !self.done
    }

    #[cfg(test)]
    fn from_receiver(receiver: mpsc::Receiver<BatchedMessage>, chunk_size: usize) -> Self {
        Self {
            receiver,
            current_batch: None,
            offset: 0,
            chunk_size,
            done: false,
            stream_error: None,
            cancelled: false,
            cancel_requested: Arc::new(AtomicBool::new(false)),
            _join: None,
        }
    }
}

pub struct AsyncStreamingState {
    receiver: mpsc::Receiver<BatchedMessage>,
    current_batch: Option<Vec<u8>>,
    offset: usize,
    chunk_size: usize,
    done: bool,
    stream_error: Option<String>,
    cancelled: bool,
    cancel_requested: Arc<AtomicBool>,
    _join: Option<JoinHandle<()>>,
}

impl AsyncStreamingState {
    /// Requests cancellation of the async stream.
    pub fn request_cancel(&self) {
        self.cancel_requested.store(true, Ordering::Relaxed);
    }

    fn pull_next_message_nonblocking(&mut self) {
        if self.done || self.stream_error.is_some() {
            return;
        }
        if self.current_batch.is_some() && self.offset < self.current_batch_len() {
            return;
        }

        match self.receiver.try_recv() {
            Ok(BatchedMessage::Batch(b)) => {
                self.current_batch = Some(b);
                self.offset = 0;
            }
            Ok(BatchedMessage::Done) => {
                self.done = true;
            }
            Ok(BatchedMessage::Cancelled) => {
                self.done = true;
                self.cancelled = true;
            }
            Ok(BatchedMessage::Error(m)) => {
                self.stream_error = Some(m);
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => {
                self.done = true;
            }
        }
    }

    fn current_batch_len(&self) -> usize {
        self.current_batch.as_ref().map_or(0, Vec::len)
    }

    /// Non-blocking poll status for async stream lifecycle.
    pub fn poll_status(&mut self) -> AsyncStreamStatus {
        self.pull_next_message_nonblocking();

        if self.stream_error.is_some() {
            return AsyncStreamStatus::Error;
        }
        if self.cancelled {
            return AsyncStreamStatus::Cancelled;
        }
        if self.done {
            return AsyncStreamStatus::Done;
        }
        if self.current_batch.is_some() && self.offset < self.current_batch_len() {
            return AsyncStreamStatus::Ready;
        }
        AsyncStreamStatus::Pending
    }

    /// Blocking fetch used for compatibility with the existing stream fetch path.
    /// If no batch is currently available, waits for the worker to produce one.
    pub fn fetch_next_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        if let Some(ref msg) = self.stream_error {
            return Err(OdbcError::InternalError(msg.clone()));
        }
        if self.done {
            return Ok(None);
        }

        let batch_len = self.current_batch_len();
        if self.current_batch.is_none() || self.offset >= batch_len {
            match self.receiver.recv() {
                Ok(BatchedMessage::Batch(b)) => {
                    self.current_batch = Some(b);
                    self.offset = 0;
                }
                Ok(BatchedMessage::Done) => {
                    self.done = true;
                    return Ok(None);
                }
                Ok(BatchedMessage::Cancelled) => {
                    self.done = true;
                    self.cancelled = true;
                    return Ok(None);
                }
                Ok(BatchedMessage::Error(m)) => {
                    self.stream_error = Some(m.clone());
                    return Err(OdbcError::InternalError(m));
                }
                Err(_) => {
                    self.done = true;
                    return Ok(None);
                }
            }
        }

        let b = self.current_batch.as_ref().ok_or_else(|| {
            OdbcError::InternalError(
                "Async stream state corrupted: no batch available after receiver processing"
                    .to_string(),
            )
        })?;
        let end = (self.offset + self.chunk_size).min(b.len());
        let chunk = b[self.offset..end].to_vec();
        self.offset = end;
        Ok(Some(chunk))
    }

    pub fn has_more(&self) -> bool {
        !self.done
    }

    #[cfg(test)]
    fn from_receiver(receiver: mpsc::Receiver<BatchedMessage>, chunk_size: usize) -> Self {
        Self {
            receiver,
            current_batch: None,
            offset: 0,
            chunk_size,
            done: false,
            stream_error: None,
            cancelled: false,
            cancel_requested: Arc::new(AtomicBool::new(false)),
            _join: None,
        }
    }
}

/// Unified streaming state: in-memory or file-backed (spill-to-disk).
pub enum StreamState {
    InMemory(StreamingState),
    FileBacked(StreamingStateFileBacked),
}

impl StreamState {
    pub fn fetch_next_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        match self {
            StreamState::InMemory(s) => s.fetch_next_chunk(),
            StreamState::FileBacked(s) => s.fetch_next_chunk(),
        }
    }

    pub fn has_more(&self) -> bool {
        match self {
            StreamState::InMemory(s) => s.has_more(),
            StreamState::FileBacked(s) => s.has_more(),
        }
    }
}

/// Streaming state backed by a temp file. Reads in chunks; deletes file on drop.
pub struct StreamingStateFileBacked {
    path: PathBuf,
    offset: usize,
    chunk_size: usize,
    total_len: usize,
}

impl StreamingStateFileBacked {
    pub fn fetch_next_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        if self.offset >= self.total_len {
            return Ok(None);
        }

        let mut f = File::open(&self.path)
            .map_err(|e| OdbcError::InternalError(format!("spill file read: {}", e)))?;
        f.seek(SeekFrom::Start(self.offset as u64))
            .map_err(|e| OdbcError::InternalError(format!("spill file seek: {}", e)))?;

        let to_read = (self.chunk_size).min(self.total_len - self.offset);
        let mut buf = vec![0u8; to_read];
        let n = f
            .read(&mut buf)
            .map_err(|e| OdbcError::InternalError(format!("spill file read: {}", e)))?;
        self.offset += n;

        if n == 0 {
            Ok(None)
        } else {
            buf.truncate(n);
            Ok(Some(buf))
        }
    }

    pub fn has_more(&self) -> bool {
        self.offset < self.total_len
    }
}

impl Drop for StreamingStateFileBacked {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

pub struct StreamingState {
    data: Vec<u8>,
    offset: usize,
    chunk_size: usize,
}

impl StreamingState {
    pub fn fetch_next_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        if self.offset >= self.data.len() {
            return Ok(None);
        }

        let end = (self.offset + self.chunk_size).min(self.data.len());
        let chunk = self.data[self.offset..end].to_vec();
        self.offset = end;

        Ok(Some(chunk))
    }

    pub fn has_more(&self) -> bool {
        self.offset < self.data.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn test_batched_streaming_state_fetch_chunks() {
        let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(2);
        let _ = tx.send(BatchedMessage::Batch(vec![1, 2, 3, 4, 5, 6]));
        let _ = tx.send(BatchedMessage::Done);
        drop(tx);

        let mut state = BatchedStreamingState::from_receiver(rx, 2);
        let c1 = state.fetch_next_chunk().unwrap();
        assert_eq!(c1, Some(vec![1, 2]));
        assert!(state.has_more());

        let c2 = state.fetch_next_chunk().unwrap();
        assert_eq!(c2, Some(vec![3, 4]));
        assert!(state.has_more());

        let c3 = state.fetch_next_chunk().unwrap();
        assert_eq!(c3, Some(vec![5, 6]));
        assert!(state.has_more());

        let c4 = state.fetch_next_chunk().unwrap();
        assert_eq!(c4, None);
        assert!(!state.has_more());
    }

    #[test]
    fn test_batched_streaming_state_error() {
        let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
        let _ = tx.send(BatchedMessage::Error("test error".to_string()));
        drop(tx);

        let mut state = BatchedStreamingState::from_receiver(rx, 10);
        let e = state.fetch_next_chunk().unwrap_err();
        assert!(e.to_string().contains("test error"));
    }

    #[test]
    fn test_async_streaming_state_poll_ready_then_done() {
        let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(2);
        let _ = tx.send(BatchedMessage::Batch(vec![10, 11, 12, 13]));
        let _ = tx.send(BatchedMessage::Done);
        drop(tx);

        let mut state = AsyncStreamingState::from_receiver(rx, 2);

        assert_eq!(state.poll_status(), AsyncStreamStatus::Ready);
        let c1 = state.fetch_next_chunk().unwrap();
        assert_eq!(c1, Some(vec![10, 11]));
        assert_eq!(state.poll_status(), AsyncStreamStatus::Ready);
        let c2 = state.fetch_next_chunk().unwrap();
        assert_eq!(c2, Some(vec![12, 13]));
        assert_eq!(state.poll_status(), AsyncStreamStatus::Done);
        let c3 = state.fetch_next_chunk().unwrap();
        assert_eq!(c3, None);
    }

    #[test]
    fn test_async_streaming_state_poll_error() {
        let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
        let _ = tx.send(BatchedMessage::Error("async test error".to_string()));
        drop(tx);

        let mut state = AsyncStreamingState::from_receiver(rx, 8);
        assert_eq!(state.poll_status(), AsyncStreamStatus::Error);
        let e = state.fetch_next_chunk().unwrap_err();
        assert!(e.to_string().contains("async test error"));
    }

    #[test]
    fn test_streaming_executor_new() {
        let executor = StreamingExecutor::new(1024);
        assert_eq!(executor.chunk_size, 1024);
    }

    #[test]
    fn test_streaming_executor_new_with_different_chunk_size() {
        let executor = StreamingExecutor::new(512);
        assert_eq!(executor.chunk_size, 512);
    }

    #[test]
    fn test_streaming_state_fetch_next_chunk() {
        let data = vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        let mut state = StreamingState {
            data,
            offset: 0,
            chunk_size: 3,
        };

        let chunk1 = state.fetch_next_chunk().unwrap();
        assert_eq!(chunk1, Some(vec![1, 2, 3]));
        assert_eq!(state.offset, 3);

        let chunk2 = state.fetch_next_chunk().unwrap();
        assert_eq!(chunk2, Some(vec![4, 5, 6]));
        assert_eq!(state.offset, 6);

        let chunk3 = state.fetch_next_chunk().unwrap();
        assert_eq!(chunk3, Some(vec![7, 8, 9]));
        assert_eq!(state.offset, 9);

        let chunk4 = state.fetch_next_chunk().unwrap();
        assert_eq!(chunk4, Some(vec![10]));
        assert_eq!(state.offset, 10);
    }

    #[test]
    fn test_streaming_state_fetch_next_chunk_returns_none_when_exhausted() {
        let data = vec![1, 2, 3];
        let mut state = StreamingState {
            data,
            offset: 0,
            chunk_size: 5,
        };

        let chunk1 = state.fetch_next_chunk().unwrap();
        assert_eq!(chunk1, Some(vec![1, 2, 3]));
        assert_eq!(state.offset, 3);

        let chunk2 = state.fetch_next_chunk().unwrap();
        assert_eq!(chunk2, None);
        assert_eq!(state.offset, 3);
    }

    #[test]
    fn test_streaming_state_fetch_next_chunk_with_exact_chunk_size() {
        let data = vec![1, 2, 3, 4, 5];
        let mut state = StreamingState {
            data,
            offset: 0,
            chunk_size: 5,
        };

        let chunk = state.fetch_next_chunk().unwrap();
        assert_eq!(chunk, Some(vec![1, 2, 3, 4, 5]));
        assert_eq!(state.offset, 5);

        let next_chunk = state.fetch_next_chunk().unwrap();
        assert_eq!(next_chunk, None);
    }

    #[test]
    fn test_streaming_state_has_more() {
        let data = vec![1, 2, 3, 4, 5];
        let mut state = StreamingState {
            data,
            offset: 0,
            chunk_size: 2,
        };

        assert!(state.has_more());

        state.fetch_next_chunk().unwrap();
        assert!(state.has_more());

        state.fetch_next_chunk().unwrap();
        assert!(state.has_more());

        state.fetch_next_chunk().unwrap();
        assert!(!state.has_more());
    }

    #[test]
    fn test_streaming_state_has_more_with_empty_data() {
        let data = vec![];
        let state = StreamingState {
            data,
            offset: 0,
            chunk_size: 10,
        };

        assert!(!state.has_more());
    }

    #[test]
    fn test_streaming_state_fetch_next_chunk_with_empty_data() {
        let data = vec![];
        let mut state = StreamingState {
            data,
            offset: 0,
            chunk_size: 10,
        };

        let chunk = state.fetch_next_chunk().unwrap();
        assert_eq!(chunk, None);
        assert!(!state.has_more());
    }
}

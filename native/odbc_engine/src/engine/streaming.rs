use crate::engine::cell_reader::read_cell_bytes;
use crate::error::{OdbcError, Result};
use crate::handles::SharedHandleManager;
use crate::protocol::{OdbcType, RowBuffer, RowBufferEncoder};
use odbc_api::{Connection, Cursor, ResultSetMetadata};
use std::sync::mpsc;
use std::thread::JoinHandle;

pub struct StreamingExecutor {
    chunk_size: usize,
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

    /// True cursor-based streaming: fetches up to `fetch_size` rows per batch,
    /// invokes `on_batch` for each encoded batch. Memory footprint is bounded
    /// by one batch instead of the full result set.
    pub fn execute_streaming_batched<F>(
        &self,
        conn: &Connection<'static>,
        sql: &str,
        fetch_size: usize,
        mut on_batch: F,
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
    /// The worker holds the HandleManager lock for the duration of the stream.
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

        let join = std::thread::spawn({
            let sql = sql.clone();
            move || {
                let Ok(guard) = handles.lock() else {
                    let _ = tx.send(BatchedMessage::Error(
                        "Failed to lock HandleManager".to_string(),
                    ));
                    return;
                };
                let conn = match guard.get_connection(conn_id) {
                    Ok(c) => c,
                    Err(e) => {
                        let _ = tx.send(BatchedMessage::Error(e.to_string()));
                        return;
                    }
                };
                let executor = StreamingExecutor::new(chunk_size);
                match executor.execute_streaming_batched(conn, &sql, fetch_size, |batch| {
                    tx.send(BatchedMessage::Batch(batch))
                        .map_err(|e| OdbcError::InternalError(e.to_string()))
                }) {
                    Ok(()) => {
                        let _ = tx.send(BatchedMessage::Done);
                    }
                    Err(e) => {
                        let _ = tx.send(BatchedMessage::Error(e.to_string()));
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
            _join: Some(join),
        })
    }
}

pub(crate) enum BatchedMessage {
    Batch(Vec<u8>),
    Done,
    Error(String),
}

pub struct BatchedStreamingState {
    receiver: mpsc::Receiver<BatchedMessage>,
    current_batch: Option<Vec<u8>>,
    offset: usize,
    chunk_size: usize,
    done: bool,
    stream_error: Option<String>,
    _join: Option<JoinHandle<()>>,
}

impl BatchedStreamingState {
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
            && self
                .current_batch
                .as_ref()
                .is_some_and(|b| self.offset < b.len())
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
            _join: None,
        }
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
        assert!(!state.has_more());

        let c4 = state.fetch_next_chunk().unwrap();
        assert_eq!(c4, None);
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

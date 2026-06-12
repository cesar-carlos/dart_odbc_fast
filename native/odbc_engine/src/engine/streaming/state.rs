use super::chunk::{
    copy_current_batch_chunk, current_batch_len, take_current_batch_chunk, StreamCopyResult,
};
use crate::error::{OdbcError, Result};
use std::fs::File;
use std::io::Read;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::thread::JoinHandle;

pub(super) struct WorkerCompletion(Option<Box<dyn FnOnce() + Send + 'static>>);

impl WorkerCompletion {
    pub(super) fn new(callback: Option<Box<dyn FnOnce() + Send + 'static>>) -> Self {
        Self(callback)
    }
}

impl Drop for WorkerCompletion {
    fn drop(&mut self) {
        if let Some(callback) = self.0.take() {
            callback();
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AsyncStreamStatus {
    Pending,
    Ready,
    Done,
    Cancelled,
    Error,
}

pub(crate) enum BatchedMessage {
    Batch(Vec<u8>),
    Done,
    Cancelled,
    Error(String),
}

pub struct BatchedStreamingState {
    receiver: mpsc::Receiver<BatchedMessage>,
    pub(crate) current_batch: Option<Vec<u8>>,
    pub(crate) offset: usize,
    chunk_size: usize,
    pub(crate) done: bool,
    pub(crate) stream_error: Option<String>,
    pub(crate) cancelled: bool,
    pub(crate) cancel_requested: Arc<AtomicBool>,
    _join: Option<JoinHandle<()>>,
}

impl BatchedStreamingState {
    pub(super) fn new(
        receiver: mpsc::Receiver<BatchedMessage>,
        chunk_size: usize,
        cancel_requested: Arc<AtomicBool>,
        join: Option<JoinHandle<()>>,
    ) -> Self {
        Self {
            receiver,
            current_batch: None,
            offset: 0,
            chunk_size,
            done: false,
            stream_error: None,
            cancelled: false,
            cancel_requested,
            _join: join,
        }
    }

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

        let batch_len = current_batch_len(&self.current_batch);
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
                Err(disc_err) => {
                    // A5 fix: receiver disconnected without sending Done/Error. The
                    // worker thread crashed or panicked. Surface as a real error
                    // instead of pretending the stream finished cleanly.
                    self.done = true;
                    let msg = format!("Stream worker disconnected unexpectedly: {disc_err}");
                    self.stream_error = Some(msg.clone());
                    return Err(OdbcError::WorkerCrashed(msg));
                }
            }
        }

        take_current_batch_chunk(
            &mut self.current_batch,
            &mut self.offset,
            self.chunk_size,
            "Streaming state corrupted: no batch available after receiver processing",
        )
    }

    pub fn copy_next_chunk(&mut self, out: &mut [u8]) -> Result<StreamCopyResult> {
        if let Some(ref msg) = self.stream_error {
            return Err(OdbcError::InternalError(msg.clone()));
        }
        if self.done {
            return Ok(StreamCopyResult::End);
        }

        let batch_len = current_batch_len(&self.current_batch);
        if self.current_batch.is_none() || self.offset >= batch_len {
            match self.receiver.recv() {
                Ok(BatchedMessage::Batch(b)) => {
                    self.current_batch = Some(b);
                    self.offset = 0;
                }
                Ok(BatchedMessage::Done) => {
                    self.done = true;
                    return Ok(StreamCopyResult::End);
                }
                Ok(BatchedMessage::Cancelled) => {
                    self.done = true;
                    self.cancelled = true;
                    return Ok(StreamCopyResult::End);
                }
                Ok(BatchedMessage::Error(m)) => {
                    self.stream_error = Some(m.clone());
                    return Err(OdbcError::InternalError(m));
                }
                Err(disc_err) => {
                    self.done = true;
                    let msg = format!("Stream worker disconnected unexpectedly: {disc_err}");
                    self.stream_error = Some(msg.clone());
                    return Err(OdbcError::WorkerCrashed(msg));
                }
            }
        }

        let has_more = self.has_more();
        copy_current_batch_chunk(
            &mut self.current_batch,
            &mut self.offset,
            self.chunk_size,
            out,
            has_more,
            "Streaming state corrupted: no batch available after receiver processing",
        )
    }

    pub fn has_more(&self) -> bool {
        !self.done
    }

    #[cfg(test)]
    pub(crate) fn from_receiver(
        receiver: mpsc::Receiver<BatchedMessage>,
        chunk_size: usize,
    ) -> Self {
        Self::new(receiver, chunk_size, Arc::new(AtomicBool::new(false)), None)
    }
}

pub struct AsyncStreamingState {
    receiver: mpsc::Receiver<BatchedMessage>,
    pub(crate) current_batch: Option<Vec<u8>>,
    pub(crate) offset: usize,
    chunk_size: usize,
    done: bool,
    stream_error: Option<String>,
    cancelled: bool,
    pub(crate) cancel_requested: Arc<AtomicBool>,
    _join: Option<JoinHandle<()>>,
}

impl AsyncStreamingState {
    pub(super) fn new(
        receiver: mpsc::Receiver<BatchedMessage>,
        chunk_size: usize,
        cancel_requested: Arc<AtomicBool>,
        join: Option<JoinHandle<()>>,
    ) -> Self {
        Self {
            receiver,
            current_batch: None,
            offset: 0,
            chunk_size,
            done: false,
            stream_error: None,
            cancelled: false,
            cancel_requested,
            _join: join,
        }
    }

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
        current_batch_len(&self.current_batch)
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
                Err(disc_err) => {
                    // A5 fix: see BatchedStreamingState above for rationale.
                    self.done = true;
                    let msg = format!("Async stream worker disconnected unexpectedly: {disc_err}");
                    self.stream_error = Some(msg.clone());
                    return Err(OdbcError::WorkerCrashed(msg));
                }
            }
        }

        take_current_batch_chunk(
            &mut self.current_batch,
            &mut self.offset,
            self.chunk_size,
            "Async stream state corrupted: no batch available after receiver processing",
        )
    }

    pub fn copy_next_chunk(&mut self, out: &mut [u8]) -> Result<StreamCopyResult> {
        if let Some(ref msg) = self.stream_error {
            return Err(OdbcError::InternalError(msg.clone()));
        }
        if self.done {
            return Ok(StreamCopyResult::End);
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
                    return Ok(StreamCopyResult::End);
                }
                Ok(BatchedMessage::Cancelled) => {
                    self.done = true;
                    self.cancelled = true;
                    return Ok(StreamCopyResult::End);
                }
                Ok(BatchedMessage::Error(m)) => {
                    self.stream_error = Some(m.clone());
                    return Err(OdbcError::InternalError(m));
                }
                Err(disc_err) => {
                    self.done = true;
                    let msg = format!("Async stream worker disconnected unexpectedly: {disc_err}");
                    self.stream_error = Some(msg.clone());
                    return Err(OdbcError::WorkerCrashed(msg));
                }
            }
        }

        let has_more = self.has_more();
        copy_current_batch_chunk(
            &mut self.current_batch,
            &mut self.offset,
            self.chunk_size,
            out,
            has_more,
            "Async stream state corrupted: no batch available after receiver processing",
        )
    }

    pub fn has_more(&self) -> bool {
        !self.done
    }

    #[cfg(test)]
    pub(crate) fn from_receiver(
        receiver: mpsc::Receiver<BatchedMessage>,
        chunk_size: usize,
    ) -> Self {
        Self::new(receiver, chunk_size, Arc::new(AtomicBool::new(false)), None)
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

    pub fn copy_next_chunk(&mut self, out: &mut [u8]) -> Result<StreamCopyResult> {
        match self {
            StreamState::InMemory(s) => s.copy_next_chunk(out),
            StreamState::FileBacked(s) => s.copy_next_chunk(out),
        }
    }
}

/// Streaming state backed by a temp file. Reads in chunks; deletes file on drop.
pub struct StreamingStateFileBacked {
    path: PathBuf,
    file: Option<File>,
    pub(crate) offset: usize,
    chunk_size: usize,
    total_len: usize,
}

impl StreamingStateFileBacked {
    pub(crate) fn new(path: PathBuf, chunk_size: usize, total_len: usize) -> Result<Self> {
        let file = File::open(&path)
            .map_err(|e| OdbcError::InternalError(format!("spill file open: {}", e)))?;
        Ok(Self {
            path,
            file: Some(file),
            offset: 0,
            chunk_size,
            total_len,
        })
    }

    pub fn fetch_next_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        if self.offset >= self.total_len {
            return Ok(None);
        }

        let to_read = (self.chunk_size).min(self.total_len - self.offset);
        let mut buf = vec![0u8; to_read];
        // A6 fix: a single `read()` may return fewer bytes than requested
        // (especially on Windows for files >64 KiB). Use `read_exact` so the
        // caller never observes a short chunk silently.
        self.file
            .as_mut()
            .ok_or_else(|| OdbcError::InternalError("spill file already closed".to_string()))?
            .read_exact(&mut buf)
            .map_err(|e| OdbcError::InternalError(format!("spill file read_exact: {}", e)))?;
        self.offset += to_read;

        if to_read == 0 {
            Ok(None)
        } else {
            Ok(Some(buf))
        }
    }

    pub fn copy_next_chunk(&mut self, out: &mut [u8]) -> Result<StreamCopyResult> {
        if self.offset >= self.total_len {
            return Ok(StreamCopyResult::End);
        }

        let to_read = self.chunk_size.min(self.total_len - self.offset);
        if out.len() < to_read {
            return Ok(StreamCopyResult::BufferTooSmall { needed: to_read });
        }

        self.file
            .as_mut()
            .ok_or_else(|| OdbcError::InternalError("spill file already closed".to_string()))?
            .read_exact(&mut out[..to_read])
            .map_err(|e| OdbcError::InternalError(format!("spill file read_exact: {}", e)))?;
        self.offset += to_read;

        Ok(StreamCopyResult::Copied {
            written: to_read,
            has_more: self.has_more(),
        })
    }

    pub fn has_more(&self) -> bool {
        self.offset < self.total_len
    }
}

impl Drop for StreamingStateFileBacked {
    fn drop(&mut self) {
        drop(self.file.take());
        let _ = std::fs::remove_file(&self.path);
    }
}

pub struct StreamingState {
    pub(crate) data: Vec<u8>,
    pub(crate) offset: usize,
    pub(crate) chunk_size: usize,
}

impl StreamingState {
    #[cfg(feature = "test-helpers")]
    #[doc(hidden)]
    pub fn from_bytes_for_benchmark(data: Vec<u8>, chunk_size: usize) -> Self {
        Self {
            data,
            offset: 0,
            chunk_size: chunk_size.max(1),
        }
    }

    pub fn fetch_next_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        if self.offset >= self.data.len() {
            return Ok(None);
        }

        let end = (self.offset + self.chunk_size).min(self.data.len());
        let chunk = self.data[self.offset..end].to_vec();
        self.offset = end;

        Ok(Some(chunk))
    }

    pub fn copy_next_chunk(&mut self, out: &mut [u8]) -> Result<StreamCopyResult> {
        if self.offset >= self.data.len() {
            return Ok(StreamCopyResult::End);
        }

        let end = self
            .offset
            .saturating_add(self.chunk_size)
            .min(self.data.len());
        let needed = end - self.offset;
        if out.len() < needed {
            return Ok(StreamCopyResult::BufferTooSmall { needed });
        }

        out[..needed].copy_from_slice(&self.data[self.offset..end]);
        self.offset = end;
        Ok(StreamCopyResult::Copied {
            written: needed,
            has_more: self.has_more(),
        })
    }

    pub fn has_more(&self) -> bool {
        self.offset < self.data.len()
    }
}

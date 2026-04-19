use crate::error::{OdbcError, Result};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;

const DEFAULT_THRESHOLD_MB: usize = 100;
const WRITE_CHUNK_SIZE: usize = 64 * 1024;

/// Adapter that implements `Write` and forwards to `DiskSpillStream::write_chunk`.
/// Buffers up to 64KB before calling write_chunk.
pub struct DiskSpillWriter<'a> {
    spill: &'a mut DiskSpillStream,
    buffer: Vec<u8>,
}

impl<'a> DiskSpillWriter<'a> {
    pub fn new(spill: &'a mut DiskSpillStream) -> Self {
        Self {
            spill,
            buffer: Vec::with_capacity(WRITE_CHUNK_SIZE),
        }
    }
}

impl Write for DiskSpillWriter<'_> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.buffer.extend_from_slice(buf);
        while self.buffer.len() >= WRITE_CHUNK_SIZE {
            let chunk: Vec<u8> = self.buffer.drain(..WRITE_CHUNK_SIZE).collect();
            self.spill
                .write_chunk(&chunk)
                .map_err(std::io::Error::other)?;
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        if !self.buffer.is_empty() {
            let chunk = std::mem::take(&mut self.buffer);
            self.spill
                .write_chunk(&chunk)
                .map_err(std::io::Error::other)?;
        }
        Ok(())
    }
}

pub struct DiskSpillStream {
    threshold_bytes: usize,
    temp_dir: PathBuf,
    temp_path: Option<PathBuf>,
    file: Option<BufWriter<File>>,
    memory_buffer: Vec<u8>,
}

impl DiskSpillStream {
    pub fn new(threshold_mb: usize) -> Self {
        let threshold_bytes = (threshold_mb.max(1)) * 1024 * 1024;
        Self {
            threshold_bytes,
            temp_dir: std::env::temp_dir(),
            temp_path: None,
            file: None,
            memory_buffer: Vec::new(),
        }
    }

    pub fn threshold_mb(&self) -> usize {
        self.threshold_bytes / (1024 * 1024)
    }

    pub fn write_chunk(&mut self, chunk: &[u8]) -> Result<()> {
        if self.file.is_some() {
            self.file
                .as_mut()
                .ok_or_else(|| OdbcError::InternalError("spill file missing".to_string()))?
                .write_all(chunk)
                .map_err(|e| OdbcError::InternalError(format!("spill write: {}", e)))?;
            return Ok(());
        }

        let would_exceed =
            self.memory_buffer.len().saturating_add(chunk.len()) > self.threshold_bytes;
        if would_exceed && !self.memory_buffer.is_empty() {
            self.spill_to_disk()?;
            self.file
                .as_mut()
                .ok_or_else(|| OdbcError::InternalError("spill file missing".to_string()))?
                .write_all(chunk)
                .map_err(|e| OdbcError::InternalError(format!("spill write: {}", e)))?;
        } else {
            self.memory_buffer.extend_from_slice(chunk);
        }
        Ok(())
    }

    fn spill_to_disk(&mut self) -> Result<()> {
        let name = format!(
            "odbc_spill_{}.bin",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis()
        );
        let path = self.temp_dir.join(name);
        let f = File::create(&path)
            .map_err(|e| OdbcError::InternalError(format!("spill create: {}", e)))?;
        let mut w = BufWriter::new(f);
        w.write_all(&self.memory_buffer)
            .map_err(|e| OdbcError::InternalError(format!("spill write: {}", e)))?;
        self.memory_buffer.clear();
        self.file = Some(w);
        self.temp_path = Some(path);
        Ok(())
    }

    pub fn read_back(&mut self) -> Result<Vec<u8>> {
        if let Some(ref mut w) = self.file {
            w.flush()
                .map_err(|e| OdbcError::InternalError(format!("spill flush: {}", e)))?;
        }
        drop(self.file.take());
        let path = self.temp_path.take();
        if let Some(p) = path {
            let data = std::fs::read(&p)
                .map_err(|e| OdbcError::InternalError(format!("spill read: {}", e)))?;
            let _ = std::fs::remove_file(p);
            Ok(data)
        } else {
            Ok(std::mem::take(&mut self.memory_buffer))
        }
    }

    /// Prepares for streaming read. If data was spilled to disk, returns the path
    /// (caller must delete when done). Otherwise returns the in-memory buffer.
    /// Flushes and closes the writer when spilled.
    pub fn finish_for_streaming_read(&mut self) -> Result<SpillReadSource> {
        if let Some(ref mut w) = self.file {
            w.flush()
                .map_err(|e| OdbcError::InternalError(format!("spill flush: {}", e)))?;
        }
        drop(self.file.take());
        let path = self.temp_path.take();
        if let Some(p) = path {
            Ok(SpillReadSource::File(p))
        } else {
            Ok(SpillReadSource::Memory(std::mem::take(
                &mut self.memory_buffer,
            )))
        }
    }
}

/// Result of `finish_for_streaming_read`: either a file path (caller reads and deletes)
/// or the in-memory buffer.
pub enum SpillReadSource {
    File(PathBuf),
    Memory(Vec<u8>),
}

impl Default for DiskSpillStream {
    fn default() -> Self {
        Self::new(DEFAULT_THRESHOLD_MB)
    }
}

impl Drop for DiskSpillStream {
    /// M4 fix: ensure any unread spill file is removed when the stream is
    /// dropped (e.g. on panic / early `?`). Best-effort: errors are logged.
    fn drop(&mut self) {
        // Drop the writer first so the OS releases the handle on Windows.
        drop(self.file.take());
        if let Some(path) = self.temp_path.take() {
            if let Err(e) = std::fs::remove_file(&path) {
                if e.kind() != std::io::ErrorKind::NotFound {
                    log::warn!(
                        "DiskSpillStream::drop: failed to remove temp file {}: {e}",
                        path.display()
                    );
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_disk_spill_new() {
        let s = DiskSpillStream::new(50);
        assert_eq!(s.threshold_mb(), 50);
    }

    #[test]
    fn test_disk_spill_default() {
        let s = DiskSpillStream::default();
        assert_eq!(s.threshold_mb(), DEFAULT_THRESHOLD_MB);
    }

    #[test]
    fn test_disk_spill_small_stays_in_memory() {
        let mut s = DiskSpillStream::new(100);
        s.write_chunk(b"hello").unwrap();
        let out = s.read_back().unwrap();
        assert_eq!(out, b"hello");
    }

    #[test]
    fn test_disk_spill_exceeds_threshold_spills_to_disk() {
        let mut s = DiskSpillStream::new(1);
        s.write_chunk(&[42]).unwrap();
        let big = vec![0u8; 2 * 1024 * 1024];
        s.write_chunk(&big).unwrap();
        let out = s.read_back().unwrap();
        assert_eq!(out.len(), 1 + 2 * 1024 * 1024);
        assert_eq!(out[0], 42);
    }
}

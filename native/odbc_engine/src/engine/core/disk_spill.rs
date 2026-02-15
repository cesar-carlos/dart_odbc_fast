use crate::error::{OdbcError, Result};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;

const DEFAULT_THRESHOLD_MB: usize = 100;

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
}

impl Default for DiskSpillStream {
    fn default() -> Self {
        Self::new(DEFAULT_THRESHOLD_MB)
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

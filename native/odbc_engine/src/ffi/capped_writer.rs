//! Writer that encodes into a Dart-allocated FFI output buffer.
//!
//! Bytes that fit are written directly to `out_buf`. When the payload exceeds
//! `buf_len` the prefix already written is copied into a `Vec` and encoding
//! continues there so the caller can stash the complete payload for a `-2`
//! retry without re-executing SQL.

use super::global_state::{set_out_written_needed, FFI_ERR_BUFFER_TOO_SMALL, FFI_OK};
use super::state;
use std::io::{self, Write};
use std::os::raw::{c_int, c_uint};

/// Incremental encoder destination backed by a caller-supplied FFI buffer.
pub(crate) struct CappedFfiWriter {
    ptr: *mut u8,
    cap: usize,
    written: usize,
    overflow: Option<Vec<u8>>,
}

pub(crate) enum CappedWriteOutcome {
    Fits { written: usize },
    Overflow { data: Vec<u8>, cap: usize },
}

impl CappedFfiWriter {
    /// # Safety
    ///
    /// `ptr` must be valid for writes of `cap` bytes for the lifetime of the
    /// writer. The FFI caller owns that allocation.
    pub(crate) unsafe fn new(ptr: *mut u8, cap: usize) -> Self {
        Self {
            ptr,
            cap,
            written: 0,
            overflow: None,
        }
    }

    pub(crate) fn finish(self) -> CappedWriteOutcome {
        match self.overflow {
            Some(data) => CappedWriteOutcome::Overflow {
                data,
                cap: self.cap,
            },
            None => CappedWriteOutcome::Fits {
                written: self.written,
            },
        }
    }
}

impl Write for CappedFfiWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        if let Some(overflow) = &mut self.overflow {
            overflow.extend_from_slice(buf);
            return Ok(buf.len());
        }
        let remaining = self.cap.saturating_sub(self.written);
        if buf.len() <= remaining {
            // SAFETY: `ptr` is valid for `cap` bytes; `written + buf.len() <= cap`.
            unsafe {
                std::ptr::copy_nonoverlapping(buf.as_ptr(), self.ptr.add(self.written), buf.len());
            }
            self.written += buf.len();
            return Ok(buf.len());
        }
        let mut data = Vec::with_capacity(self.written + buf.len());
        if self.written > 0 {
            // SAFETY: prefix `written` bytes were stored at `ptr`.
            unsafe {
                data.extend_from_slice(std::slice::from_raw_parts(self.ptr, self.written));
            }
        }
        data.extend_from_slice(buf);
        self.overflow = Some(data);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Completes a capped encode: success writes `out_written`, overflow stashes.
///
/// `pending_key` is only built on overflow so the hot success path does not
/// hash SQL or parameters.
pub(crate) fn deliver_capped_outcome(
    conn_id: u32,
    outcome: CappedWriteOutcome,
    out_written: *mut c_uint,
    pending_key: impl FnOnce() -> state::PendingResultKey,
) -> c_int {
    deliver_capped_outcome_maybe_stash(conn_id, outcome, out_written, Some(pending_key))
}

/// Same as [`deliver_capped_outcome`] without a `-2` stash (catalog/metadata).
pub(crate) fn deliver_capped_outcome_without_stash(
    conn_id: u32,
    outcome: CappedWriteOutcome,
    out_written: *mut c_uint,
) -> c_int {
    deliver_capped_outcome_maybe_stash(
        conn_id,
        outcome,
        out_written,
        None::<fn() -> state::PendingResultKey>,
    )
}

/// Copies an already-built payload into the Dart buffer, overflowing to a Vec.
pub(crate) fn capped_outcome_from_bytes(
    data: &[u8],
    out_buf: *mut u8,
    buf_len: usize,
) -> CappedWriteOutcome {
    if data.len() <= buf_len {
        if !data.is_empty() && !out_buf.is_null() {
            // SAFETY: FFI caller owns `out_buf` for `buf_len` bytes; `data.len() <= buf_len`.
            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr(), out_buf, data.len());
            }
            crate::ffi::global_state::record_ffi_memcpy_bytes(data.len());
        }
        CappedWriteOutcome::Fits {
            written: data.len(),
        }
    } else {
        CappedWriteOutcome::Overflow {
            data: data.to_vec(),
            cap: buf_len,
        }
    }
}

/// Moves an owned payload into the Dart buffer without cloning on overflow.
pub(crate) fn capped_outcome_from_vec(
    data: Vec<u8>,
    out_buf: *mut u8,
    buf_len: usize,
) -> CappedWriteOutcome {
    if data.len() <= buf_len {
        capped_outcome_from_bytes(&data, out_buf, buf_len)
    } else {
        CappedWriteOutcome::Overflow { data, cap: buf_len }
    }
}

fn deliver_capped_outcome_maybe_stash(
    conn_id: u32,
    outcome: CappedWriteOutcome,
    out_written: *mut c_uint,
    pending_key: Option<impl FnOnce() -> state::PendingResultKey>,
) -> c_int {
    match outcome {
        CappedWriteOutcome::Fits { written } => {
            if !out_written.is_null() {
                // SAFETY: caller guaranteed `out_written` is writable for this FFI call.
                unsafe { *out_written = written.min(c_uint::MAX as usize) as c_uint };
            }
            FFI_OK
        }
        CappedWriteOutcome::Overflow { data, cap } => {
            let error = format!("Buffer too small: need {} bytes, got {}", data.len(), cap);
            state::set_connection_error(conn_id, error.clone());
            state::set_legacy_global_error(error);
            set_out_written_needed(out_written, data.len());
            match pending_key {
                Some(key) => {
                    state::stash_if_buffer_too_small(FFI_ERR_BUFFER_TOO_SMALL, key(), data)
                }
                None => FFI_ERR_BUFFER_TOO_SMALL,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::row_buffer::RowBuffer;
    use crate::protocol::types::OdbcType;
    use crate::protocol::RowBufferEncoder;
    use std::io::Write;

    #[test]
    fn capped_writer_matches_encode_result_when_buffer_fits() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("n".to_string(), OdbcType::Integer);
        buffer.add_row_vecs(vec![Some(1i32.to_le_bytes().to_vec())]);
        let expected = RowBufferEncoder::encode_result(&buffer).expect("encode");
        let mut dest = vec![0u8; expected.len()];
        let mut writer = unsafe { CappedFfiWriter::new(dest.as_mut_ptr(), dest.len()) };
        RowBufferEncoder::encode_to_writer_result(&buffer, &mut writer).expect("write");
        match writer.finish() {
            CappedWriteOutcome::Fits { written } => {
                assert_eq!(written, expected.len());
                assert_eq!(&dest[..written], expected.as_slice());
            }
            CappedWriteOutcome::Overflow { .. } => panic!("expected fit"),
        }
    }

    #[test]
    fn capped_writer_fit_does_not_count_ffi_memcpy() {
        crate::ffi::global_state::reset_ffi_memcpy_bytes();
        let mut dest = vec![0u8; 16];
        let mut writer = unsafe { CappedFfiWriter::new(dest.as_mut_ptr(), dest.len()) };
        writer.write_all(b"hello").expect("write");
        match writer.finish() {
            CappedWriteOutcome::Fits { written } => assert_eq!(written, 5),
            CappedWriteOutcome::Overflow { .. } => panic!("expected fit"),
        }
        assert_eq!(crate::ffi::global_state::ffi_memcpy_bytes(), 0);
    }

    #[test]
    fn capped_writer_overflows_to_complete_vec() {
        let mut buffer = RowBuffer::new();
        buffer.add_column("n".to_string(), OdbcType::Integer);
        buffer.add_row_vecs(vec![Some(1i32.to_le_bytes().to_vec())]);
        let expected = RowBufferEncoder::encode_result(&buffer).expect("encode");
        assert!(expected.len() > 4);
        let mut dest = vec![0u8; 4];
        let mut writer = unsafe { CappedFfiWriter::new(dest.as_mut_ptr(), dest.len()) };
        RowBufferEncoder::encode_to_writer_result(&buffer, &mut writer).expect("write");
        match writer.finish() {
            CappedWriteOutcome::Overflow { data, cap } => {
                assert_eq!(cap, 4);
                assert_eq!(data, expected);
            }
            CappedWriteOutcome::Fits { .. } => panic!("expected overflow"),
        }
    }
}

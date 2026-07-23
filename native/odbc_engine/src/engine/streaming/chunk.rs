use crate::error::{OdbcError, Result};

#[derive(Debug, PartialEq, Eq)]
pub enum StreamCopyResult {
    Copied { written: usize, has_more: bool },
    End,
    BufferTooSmall { needed: usize },
}

pub(super) fn current_batch_len(current_batch: &Option<Vec<u8>>) -> usize {
    current_batch.as_ref().map_or(0, Vec::len)
}

pub(super) fn take_current_batch_chunk(
    current_batch: &mut Option<Vec<u8>>,
    offset: &mut usize,
    chunk_size: usize,
    missing_batch_message: &'static str,
) -> Result<Option<Vec<u8>>> {
    // Owned-Vec API: transfer limit is `chunk_size` (may take the whole batch
    // when offset==0 and chunk_size covers it). Distinct from
    // `copy_current_batch_chunk`, which fills the caller FFI buffer (`out.len()`).
    let batch_len = current_batch
        .as_ref()
        .map(Vec::len)
        .ok_or_else(|| OdbcError::InternalError(missing_batch_message.to_string()))?;
    if *offset == 0 && chunk_size >= batch_len {
        return Ok(current_batch.take());
    }

    let batch = current_batch
        .as_ref()
        .ok_or_else(|| OdbcError::InternalError(missing_batch_message.to_string()))?;
    let end = (*offset).saturating_add(chunk_size).min(batch.len());
    let chunk = batch[*offset..end].to_vec();
    *offset = end;
    Ok(Some(chunk))
}

pub(super) fn copy_current_batch_chunk(
    current_batch: &mut Option<Vec<u8>>,
    offset: &mut usize,
    chunk_size: usize,
    out: &mut [u8],
    has_more: bool,
    missing_batch_message: &'static str,
) -> Result<StreamCopyResult> {
    // FFI hot path: fill `out.len()` to minimize round-trips. `chunk_size` is
    // retained for API parity with take_* but is not the copy limit here.
    let _ = chunk_size;
    let batch = current_batch
        .as_ref()
        .ok_or_else(|| OdbcError::InternalError(missing_batch_message.to_string()))?;
    let end = (*offset).saturating_add(out.len()).min(batch.len());
    let needed = end - *offset;
    if out.len() < needed {
        return Ok(StreamCopyResult::BufferTooSmall { needed });
    }

    out[..needed].copy_from_slice(&batch[*offset..end]);
    *offset = end;
    if *offset >= batch.len() {
        *current_batch = None;
        *offset = 0;
    }
    Ok(StreamCopyResult::Copied {
        written: needed,
        has_more,
    })
}

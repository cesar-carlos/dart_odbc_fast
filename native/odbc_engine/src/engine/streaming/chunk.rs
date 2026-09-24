use crate::error::{OdbcError, Result};
use std::sync::{Mutex, TryLockError};

const MAX_IDLE_BATCH_BUFFERS: usize = 2;
const MAX_RETAINED_BATCH_CAPACITY: usize = 8 * 1024 * 1024;

#[derive(Default)]
pub(super) struct BatchBufferPool {
    idle: Mutex<Vec<Vec<u8>>>,
}

impl BatchBufferPool {
    pub(super) fn take(&self) -> Vec<u8> {
        match self.idle.try_lock() {
            Ok(mut idle) => idle.pop().unwrap_or_default(),
            Err(TryLockError::Poisoned(poisoned)) => {
                log::error!("batch output pool mutex poisoned during take");
                poisoned.into_inner().pop().unwrap_or_default()
            }
            Err(TryLockError::WouldBlock) => Vec::new(),
        }
    }

    pub(super) fn recycle(&self, mut buffer: Vec<u8>) {
        if buffer.capacity() > MAX_RETAINED_BATCH_CAPACITY {
            return;
        }
        buffer.clear();
        match self.idle.try_lock() {
            Ok(mut idle) => retain_idle_buffer(&mut idle, buffer),
            Err(TryLockError::Poisoned(poisoned)) => {
                log::error!("batch output pool mutex poisoned during recycle");
                retain_idle_buffer(&mut poisoned.into_inner(), buffer);
            }
            Err(TryLockError::WouldBlock) => {}
        }
    }
}

fn retain_idle_buffer(idle: &mut Vec<Vec<u8>>, buffer: Vec<u8>) {
    if idle.len() < MAX_IDLE_BATCH_BUFFERS {
        idle.push(buffer);
    }
}

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
    pool: Option<&BatchBufferPool>,
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
    if end == batch.len() {
        if let Some(consumed) = current_batch.take() {
            if let Some(pool) = pool {
                pool.recycle(consumed);
            }
        }
        *offset = 0;
    }
    Ok(Some(chunk))
}

pub(super) fn copy_current_batch_chunk(
    current_batch: &mut Option<Vec<u8>>,
    offset: &mut usize,
    chunk_size: usize,
    out: &mut [u8],
    has_more: bool,
    missing_batch_message: &'static str,
    pool: Option<&BatchBufferPool>,
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
        if let Some(batch) = current_batch.take() {
            if let Some(pool) = pool {
                pool.recycle(batch);
            }
        }
        *offset = 0;
    }
    Ok(StreamCopyResult::Copied {
        written: needed,
        has_more,
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn buffer_pool_reuses_only_bounded_capacities() {
        use super::{BatchBufferPool, MAX_RETAINED_BATCH_CAPACITY};
        let pool = BatchBufferPool::default();
        let mut first = Vec::with_capacity(4096);
        first.extend_from_slice(&[1, 2, 3]);
        let pointer = first.as_ptr();
        pool.recycle(first);
        let reused = pool.take();
        assert_eq!(reused.as_ptr(), pointer);
        assert!(reused.is_empty());
        pool.recycle(reused);
        pool.recycle(Vec::with_capacity(1024));
        pool.recycle(Vec::with_capacity(1024));
        assert_eq!(pool.idle.lock().expect("pool lock").len(), 2);
        pool.recycle(Vec::with_capacity(MAX_RETAINED_BATCH_CAPACITY + 1));
        assert_eq!(pool.idle.lock().expect("pool lock").len(), 2);
    }

    #[test]
    fn full_copy_recycles_batch_but_partial_copy_retains_it() {
        use super::{copy_current_batch_chunk, BatchBufferPool, StreamCopyResult};
        let pool = BatchBufferPool::default();
        let batch = vec![1, 2, 3, 4];
        let pointer = batch.as_ptr();
        let mut current = Some(batch);
        let mut offset = 0;
        let mut output = [0; 2];
        let first = copy_current_batch_chunk(
            &mut current,
            &mut offset,
            2,
            &mut output,
            true,
            "missing",
            Some(&pool),
        )
        .expect("first copy");
        assert_eq!(
            first,
            StreamCopyResult::Copied {
                written: 2,
                has_more: true
            }
        );
        assert_eq!(output, [1, 2]);
        assert!(current.is_some());
        assert!(pool.idle.lock().expect("pool lock").is_empty());
        let second = copy_current_batch_chunk(
            &mut current,
            &mut offset,
            2,
            &mut output,
            true,
            "missing",
            Some(&pool),
        )
        .expect("second copy");
        assert_eq!(
            second,
            StreamCopyResult::Copied {
                written: 2,
                has_more: true
            }
        );
        assert_eq!(output, [3, 4]);
        assert!(current.is_none());
        let reused = pool.take();
        assert_eq!(reused.as_ptr(), pointer);
    }

    #[test]
    fn recycled_multi_buffer_resets_frame_prefix() {
        use super::super::batched_fetch::{begin_batch_output, finish_batch_frame};
        use super::BatchBufferPool;

        let pool = BatchBufferPool::default();
        let mut old = vec![9u8; 128];
        old[0] = 77;
        let pointer = old.as_ptr();
        pool.recycle(old);
        let mut frame = begin_batch_output(Some(2), Some(&pool));
        assert_eq!(frame.as_ptr(), pointer);
        assert_eq!(frame, [0, 0, 0, 0, 0]);
        frame.extend_from_slice(&[3, 4]);
        finish_batch_frame(&mut frame, Some(2)).expect("frame length");
        assert_eq!(frame, [2, 2, 0, 0, 0, 3, 4]);
    }

    #[test]
    fn partial_owned_chunks_recycle_source_but_whole_owned_chunk_transfers_it() {
        use super::{take_current_batch_chunk, BatchBufferPool};

        let pool = BatchBufferPool::default();
        let mut batch = Some(vec![1, 2, 3, 4]);
        let pointer = batch.as_ref().expect("batch").as_ptr();
        let mut offset = 0;
        assert_eq!(
            take_current_batch_chunk(&mut batch, &mut offset, 2, "missing", Some(&pool))
                .expect("first chunk"),
            Some(vec![1, 2])
        );
        assert!(pool.idle.lock().expect("pool lock").is_empty());
        assert_eq!(
            take_current_batch_chunk(&mut batch, &mut offset, 2, "missing", Some(&pool))
                .expect("second chunk"),
            Some(vec![3, 4])
        );
        assert!(batch.is_none());
        let recycled = pool.take();
        assert_eq!(recycled.as_ptr(), pointer);

        let whole = vec![5, 6];
        let pointer = whole.as_ptr();
        let mut batch = Some(whole);
        let result = take_current_batch_chunk(&mut batch, &mut offset, 2, "missing", Some(&pool))
            .expect("whole chunk")
            .expect("payload");
        assert_eq!(result.as_ptr(), pointer);
        assert!(pool.idle.lock().expect("pool lock").is_empty());
    }
}

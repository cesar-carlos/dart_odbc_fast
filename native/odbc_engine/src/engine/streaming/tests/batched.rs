use super::super::chunk::StreamCopyResult;
use super::super::multi_result::{
    frame_item, MULTI_STREAM_ITEM_TAG_RESULT_SET, MULTI_STREAM_ITEM_TAG_ROW_COUNT,
};
use super::super::state::{
    AsyncStreamStatus, AsyncStreamingState, BatchedMessage, BatchedStreamingState, StreamState,
    StreamingState, StreamingStateFileBacked,
};
use super::super::worker::StreamingExecutor;
use crate::engine::core::{DiskSpillStream, DiskSpillWriter, SpillReadSource};
use crate::error::OdbcError;
use crate::protocol::{OdbcType, RowBuffer, RowBufferEncoder};
use std::io::Write;
use std::sync::atomic::Ordering;
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
fn test_batched_streaming_state_takes_whole_batch_when_chunk_fits() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(2);
    let _ = tx.send(BatchedMessage::Batch(vec![1, 2, 3]));
    let _ = tx.send(BatchedMessage::Done);
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 8);
    let chunk = state.fetch_next_chunk().unwrap();

    assert_eq!(chunk, Some(vec![1, 2, 3]));
    assert!(state.current_batch.is_none());
    assert_eq!(state.fetch_next_chunk().unwrap(), None);
}
#[test]
fn test_batched_streaming_state_copy_fills_partial_out_without_buffer_too_small() {
    // With copy limited by out.len() (not chunk_size), a tiny caller buffer
    // receives a partial copy and advances offset — BufferTooSmall is not
    // returned when out can hold at least one byte of the remaining batch.
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(2);
    let _ = tx.send(BatchedMessage::Batch(vec![1, 2, 3, 4]));
    let _ = tx.send(BatchedMessage::Done);
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 3);
    let mut tiny = [0u8; 2];
    assert_eq!(
        state.copy_next_chunk(&mut tiny).unwrap(),
        StreamCopyResult::Copied {
            written: 2,
            has_more: true
        }
    );
    assert_eq!(&tiny, &[1, 2]);

    let mut out = [0u8; 3];
    assert_eq!(
        state.copy_next_chunk(&mut out).unwrap(),
        StreamCopyResult::Copied {
            written: 2,
            has_more: true
        }
    );
    assert_eq!(&out[..2], &[3, 4]);
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
fn test_batched_streaming_state_cancelled_returns_end() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Cancelled);
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 4);
    assert_eq!(state.fetch_next_chunk().unwrap(), None);
    assert!(state.cancelled);
    assert!(!state.has_more());
}
#[test]
fn test_batched_streaming_state_worker_disconnect_returns_worker_crashed() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 4);
    let err = state.fetch_next_chunk().unwrap_err();
    assert!(matches!(err, OdbcError::WorkerCrashed(_)));
    assert!(state.stream_error.is_some());
}
#[test]
fn test_batched_streaming_state_multiple_batches() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(4);
    let _ = tx.send(BatchedMessage::Batch(vec![1, 2]));
    let _ = tx.send(BatchedMessage::Batch(vec![3, 4]));
    let _ = tx.send(BatchedMessage::Done);
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 4);
    assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![1, 2]));
    assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![3, 4]));
    assert_eq!(state.fetch_next_chunk().unwrap(), None);
}
#[test]
fn test_batched_request_cancel_sets_atomic_flag() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let state = BatchedStreamingState::from_receiver(rx, 4);
    assert!(!state.cancel_requested.load(Ordering::Relaxed));
    state.request_cancel();
    assert!(state.cancel_requested.load(Ordering::Relaxed));
    drop(tx);
}
#[test]
fn test_batched_fetch_repeats_stream_error_without_recv() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Error("sticky".to_string()));
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 4);
    let e1 = state.fetch_next_chunk().unwrap_err();
    let e2 = state.fetch_next_chunk().unwrap_err();
    assert!(e1.to_string().contains("sticky"));
    assert!(e2.to_string().contains("sticky"));
}
#[test]
fn test_batched_copy_returns_end_when_already_done() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Done);
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 4);
    assert_eq!(state.fetch_next_chunk().unwrap(), None);
    let mut out = [0u8; 8];
    assert_eq!(
        state.copy_next_chunk(&mut out).unwrap(),
        StreamCopyResult::End
    );
}
#[test]
fn test_batched_copy_sticky_stream_error() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Error("copy sticky".to_string()));
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 4);
    let mut out = [0u8; 4];
    let e1 = state.copy_next_chunk(&mut out).unwrap_err();
    let e2 = state.copy_next_chunk(&mut out).unwrap_err();
    assert!(e1.to_string().contains("copy sticky"));
    assert!(e2.to_string().contains("copy sticky"));
}
#[test]
fn test_batched_copy_returns_error_from_worker() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Error("copy fail".to_string()));
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 4);
    let mut out = [0u8; 8];
    let err = state.copy_next_chunk(&mut out).unwrap_err();
    assert!(err.to_string().contains("copy fail"));
}
#[test]
fn test_batched_copy_clears_batch_after_full_read() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(2);
    let _ = tx.send(BatchedMessage::Batch(vec![1, 2, 3]));
    let _ = tx.send(BatchedMessage::Done);
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 3);
    let mut out = [0u8; 3];
    assert_eq!(
        state.copy_next_chunk(&mut out).unwrap(),
        StreamCopyResult::Copied {
            written: 3,
            has_more: true
        }
    );
    assert!(state.current_batch.is_none());
    assert_eq!(state.offset, 0);
}
#[test]
fn test_batched_fetch_returns_none_when_done_flag_set() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Done);
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 4);
    assert_eq!(state.fetch_next_chunk().unwrap(), None);
    assert!(!state.has_more());
    assert_eq!(state.fetch_next_chunk().unwrap(), None);
}
#[test]
fn test_batched_worker_crashed_fetch_is_sticky() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 4);
    let e1 = state.fetch_next_chunk().unwrap_err();
    let e2 = state.fetch_next_chunk().unwrap_err();
    assert!(matches!(e1, OdbcError::WorkerCrashed(_)));
    assert!(matches!(e2, OdbcError::InternalError(_)));
    assert!(e2.to_string().contains("disconnected"));
    assert!(state.done);
}
#[test]
fn test_batched_worker_crashed_copy_is_sticky() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 4);
    let mut out = [0u8; 4];
    let e1 = state.copy_next_chunk(&mut out).unwrap_err();
    let e2 = state.copy_next_chunk(&mut out).unwrap_err();
    assert!(matches!(e1, OdbcError::WorkerCrashed(_)));
    assert!(matches!(e2, OdbcError::InternalError(_)));
}
#[test]
fn test_batched_has_more_false_after_worker_crashed() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 4);
    let _ = state.fetch_next_chunk().unwrap_err();
    assert!(!state.has_more());
}
#[test]
fn test_batched_stream_error_sets_has_more_until_fetch() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Error("before fetch".to_string()));
    drop(tx);

    let state = BatchedStreamingState::from_receiver(rx, 4);
    assert!(state.has_more());
}
#[test]
fn test_batched_copy_returns_end_when_cancelled() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Cancelled);
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 4);
    let mut out = [0u8; 8];
    assert_eq!(
        state.copy_next_chunk(&mut out).unwrap(),
        StreamCopyResult::End
    );
    assert!(state.cancelled);
    assert!(!state.has_more());
}
#[test]
fn test_batched_has_more_false_after_done_message() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Done);
    drop(tx);

    let mut state = BatchedStreamingState::from_receiver(rx, 4);
    assert!(state.has_more());
    assert_eq!(state.fetch_next_chunk().unwrap(), None);
    assert!(!state.has_more());
}

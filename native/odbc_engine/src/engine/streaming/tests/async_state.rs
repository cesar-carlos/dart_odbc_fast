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
fn test_async_streaming_state_takes_whole_batch_when_chunk_fits() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(2);
    let _ = tx.send(BatchedMessage::Batch(vec![7, 8, 9]));
    let _ = tx.send(BatchedMessage::Done);
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 16);

    assert_eq!(state.poll_status(), AsyncStreamStatus::Ready);
    assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![7, 8, 9]));
    assert!(state.current_batch.is_none());
    assert_eq!(state.fetch_next_chunk().unwrap(), None);
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
fn test_async_streaming_state_poll_cancelled() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Cancelled);
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 4);
    assert_eq!(state.poll_status(), AsyncStreamStatus::Cancelled);
    assert_eq!(state.fetch_next_chunk().unwrap(), None);
}
#[test]
fn test_async_streaming_state_worker_disconnect_returns_worker_crashed() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 4);
    // Blocking fetch surfaces WorkerCrashed; poll_status only marks Done.
    let err = state.fetch_next_chunk().unwrap_err();
    assert!(matches!(err, OdbcError::WorkerCrashed(_)));
}
#[test]
fn test_async_streaming_state_poll_pending_before_batch() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let mut state = AsyncStreamingState::from_receiver(rx, 4);
    assert_eq!(state.poll_status(), AsyncStreamStatus::Pending);
    let _ = tx.send(BatchedMessage::Batch(vec![9]));
    assert_eq!(state.poll_status(), AsyncStreamStatus::Ready);
}
#[test]
fn test_async_request_cancel_sets_atomic_flag() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let state = AsyncStreamingState::from_receiver(rx, 4);
    assert!(!state.cancel_requested.load(Ordering::Relaxed));
    state.request_cancel();
    assert!(state.cancel_requested.load(Ordering::Relaxed));
    drop(tx);
}
#[test]
fn test_async_copy_next_chunk_splits_across_chunk_size() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(2);
    let _ = tx.send(BatchedMessage::Batch(vec![1, 2, 3, 4, 5]));
    let _ = tx.send(BatchedMessage::Done);
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 2);
    let mut out = [0u8; 2];
    assert_eq!(
        state.copy_next_chunk(&mut out).unwrap(),
        StreamCopyResult::Copied {
            written: 2,
            has_more: true
        }
    );
    assert_eq!(&out, &[1, 2]);
    assert_eq!(
        state.copy_next_chunk(&mut out).unwrap(),
        StreamCopyResult::Copied {
            written: 2,
            has_more: true
        }
    );
    assert_eq!(&out, &[3, 4]);
    let mut last = [0u8; 1];
    assert_eq!(
        state.copy_next_chunk(&mut last).unwrap(),
        StreamCopyResult::Copied {
            written: 1,
            has_more: true
        }
    );
    assert_eq!(last[0], 5);
}

#[test]
fn test_async_copy_fills_out_buffer_even_when_larger_than_chunk_size() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(2);
    let _ = tx.send(BatchedMessage::Batch(vec![1, 2, 3, 4, 5]));
    let _ = tx.send(BatchedMessage::Done);
    drop(tx);

    // chunk_size=2, but out is larger — one copy should take the whole batch.
    let mut state = AsyncStreamingState::from_receiver(rx, 2);
    let mut out = [0u8; 8];
    assert_eq!(
        state.copy_next_chunk(&mut out).unwrap(),
        StreamCopyResult::Copied {
            written: 5,
            has_more: true
        }
    );
    assert_eq!(&out[..5], &[1, 2, 3, 4, 5]);
}
#[test]
fn test_async_poll_disconnected_marks_done_before_blocking_fetch() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 4);
    // Non-blocking poll treats disconnect as a clean Done (no WorkerCrashed).
    assert_eq!(state.poll_status(), AsyncStreamStatus::Done);
    assert_eq!(state.fetch_next_chunk().unwrap(), None);
}
#[test]
fn test_async_fetch_without_prior_poll_surfaces_worker_crashed_on_disconnect() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 4);
    let err = state.fetch_next_chunk().unwrap_err();
    assert!(matches!(err, OdbcError::WorkerCrashed(_)));
}
#[test]
fn test_async_copy_sticky_stream_error() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Error("async copy sticky".to_string()));
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 4);
    let mut out = [0u8; 4];
    let e1 = state.copy_next_chunk(&mut out).unwrap_err();
    let e2 = state.copy_next_chunk(&mut out).unwrap_err();
    assert!(e1.to_string().contains("async copy sticky"));
    assert!(e2.to_string().contains("async copy sticky"));
}
#[test]
fn test_async_poll_ready_when_offset_mid_batch() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(2);
    let _ = tx.send(BatchedMessage::Batch(vec![1, 2, 3, 4]));
    let _ = tx.send(BatchedMessage::Done);
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 2);
    assert_eq!(state.poll_status(), AsyncStreamStatus::Ready);
    let mut out = [0u8; 2];
    assert_eq!(
        state.copy_next_chunk(&mut out).unwrap(),
        StreamCopyResult::Copied {
            written: 2,
            has_more: true
        }
    );
    assert_eq!(state.poll_status(), AsyncStreamStatus::Ready);
    assert_eq!(state.offset, 2);
}
#[test]
fn test_async_fetch_sticky_error_without_poll() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Error("fetch sticky".to_string()));
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 4);
    let e1 = state.fetch_next_chunk().unwrap_err();
    let e2 = state.fetch_next_chunk().unwrap_err();
    assert!(e1.to_string().contains("fetch sticky"));
    assert!(e2.to_string().contains("fetch sticky"));
    assert_eq!(state.poll_status(), AsyncStreamStatus::Error);
}
#[test]
fn test_async_poll_error_stays_error_on_repeat() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Error("poll sticky".to_string()));
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 4);
    assert_eq!(state.poll_status(), AsyncStreamStatus::Error);
    assert_eq!(state.poll_status(), AsyncStreamStatus::Error);
    let err = state.fetch_next_chunk().unwrap_err();
    assert!(err.to_string().contains("poll sticky"));
}
#[test]
fn test_async_copy_worker_crashed_is_sticky() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 4);
    let mut out = [0u8; 2];
    let e1 = state.copy_next_chunk(&mut out).unwrap_err();
    let e2 = state.copy_next_chunk(&mut out).unwrap_err();
    assert!(matches!(e1, OdbcError::WorkerCrashed(_)));
    assert!(matches!(e2, OdbcError::InternalError(_)));
}
#[test]
fn test_async_stream_status_variants_are_distinct() {
    let statuses = [
        AsyncStreamStatus::Pending,
        AsyncStreamStatus::Ready,
        AsyncStreamStatus::Done,
        AsyncStreamStatus::Cancelled,
        AsyncStreamStatus::Error,
    ];
    for (i, a) in statuses.iter().enumerate() {
        for (j, b) in statuses.iter().enumerate() {
            if i == j {
                assert_eq!(a, b);
            } else {
                assert_ne!(a, b);
            }
        }
    }
}
#[test]
fn test_async_copy_returns_end_when_cancelled() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Cancelled);
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 4);
    let mut out = [0u8; 8];
    assert_eq!(
        state.copy_next_chunk(&mut out).unwrap(),
        StreamCopyResult::End
    );
    assert_eq!(state.poll_status(), AsyncStreamStatus::Cancelled);
}
#[test]
fn test_async_poll_cancelled_after_draining_queued_batch() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(2);
    let _ = tx.send(BatchedMessage::Batch(vec![1, 2, 3]));
    let _ = tx.send(BatchedMessage::Cancelled);
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 8);
    assert_eq!(state.poll_status(), AsyncStreamStatus::Ready);
    assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![1, 2, 3]));
    assert_eq!(state.poll_status(), AsyncStreamStatus::Cancelled);
    assert_eq!(state.fetch_next_chunk().unwrap(), None);
}
#[test]
fn test_async_has_more_false_after_poll_done() {
    let (tx, rx) = mpsc::sync_channel::<BatchedMessage>(1);
    let _ = tx.send(BatchedMessage::Done);
    drop(tx);

    let mut state = AsyncStreamingState::from_receiver(rx, 4);
    assert_eq!(state.poll_status(), AsyncStreamStatus::Done);
    assert!(!state.has_more());
}

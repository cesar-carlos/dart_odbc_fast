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
fn test_streaming_state_copy_next_chunk_writes_without_advancing_on_small_buffer() {
    let data = vec![1, 2, 3, 4, 5];
    let mut state = StreamingState {
        data,
        offset: 0,
        chunk_size: 4,
    };

    let mut tiny = [0u8; 3];
    assert_eq!(
        state.copy_next_chunk(&mut tiny).unwrap(),
        StreamCopyResult::BufferTooSmall { needed: 4 }
    );
    assert_eq!(state.offset, 0);

    let mut out = [0u8; 4];
    assert_eq!(
        state.copy_next_chunk(&mut out).unwrap(),
        StreamCopyResult::Copied {
            written: 4,
            has_more: true
        }
    );
    assert_eq!(&out, &[1, 2, 3, 4]);
    assert_eq!(state.offset, 4);
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
#[test]
fn test_stream_state_in_memory_delegates_fetch() {
    let mut state = StreamState::InMemory(StreamingState {
        data: vec![1, 2, 3],
        offset: 0,
        chunk_size: 2,
    });
    assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![1, 2]));
    assert!(state.has_more());
}
#[test]
fn test_stream_state_copy_next_chunk_delegates_to_in_memory() {
    let mut state = StreamState::InMemory(StreamingState {
        data: vec![5, 6],
        offset: 0,
        chunk_size: 2,
    });
    let mut out = [0u8; 2];
    assert_eq!(
        state.copy_next_chunk(&mut out).unwrap(),
        StreamCopyResult::Copied {
            written: 2,
            has_more: false
        }
    );
    assert_eq!(&out, &[5, 6]);
}
#[test]
fn test_streaming_state_copy_returns_end_when_exhausted() {
    let mut state = StreamingState {
        data: vec![1, 2],
        offset: 2,
        chunk_size: 4,
    };
    let mut out = [0u8; 4];
    assert_eq!(
        state.copy_next_chunk(&mut out).unwrap(),
        StreamCopyResult::End
    );
    assert!(!state.has_more());
}
#[test]
fn test_stream_state_in_memory_has_more_false_when_exhausted() {
    let mut state = StreamState::InMemory(StreamingState {
        data: vec![1],
        offset: 0,
        chunk_size: 8,
    });
    assert!(state.has_more());
    assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![1]));
    assert!(!state.has_more());
    assert_eq!(state.fetch_next_chunk().unwrap(), None);
}
#[test]
fn test_stream_copy_result_variants_are_distinct() {
    let copied = StreamCopyResult::Copied {
        written: 1,
        has_more: true,
    };
    let end = StreamCopyResult::End;
    let small = StreamCopyResult::BufferTooSmall { needed: 4 };
    assert_ne!(copied, end);
    assert_ne!(copied, small);
    assert_ne!(end, small);
}
#[test]
fn test_streaming_state_fetch_resumes_from_mid_offset() {
    let mut state = StreamingState {
        data: vec![10, 20, 30, 40, 50],
        offset: 2,
        chunk_size: 2,
    };
    assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![30, 40]));
    assert_eq!(state.offset, 4);
    assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![50]));
}

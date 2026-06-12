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
fn test_file_backed_streaming_state_keeps_file_open_and_cleans_up() {
    let path = std::env::temp_dir().join(format!(
        "odbc_streaming_state_test_{}.bin",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::write(&path, [1u8, 2, 3, 4, 5, 6, 7]).unwrap();

    {
        let mut state = StreamingStateFileBacked::new(path.clone(), 3, 7).unwrap();

        assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![1, 2, 3]));
        assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![4, 5, 6]));
        assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![7]));
        assert_eq!(state.fetch_next_chunk().unwrap(), None);
    }

    assert!(!path.exists(), "file-backed stream should remove temp file");
}
#[test]
fn test_file_backed_streaming_state_copy_preserves_offset_when_buffer_too_small() {
    let path = std::env::temp_dir().join(format!(
        "odbc_streaming_state_copy_test_{}.bin",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::write(&path, [9u8, 8, 7, 6]).unwrap();

    {
        let mut state = StreamingStateFileBacked::new(path.clone(), 3, 4).unwrap();
        let mut tiny = [0u8; 2];
        assert_eq!(
            state.copy_next_chunk(&mut tiny).unwrap(),
            StreamCopyResult::BufferTooSmall { needed: 3 }
        );

        let mut out = [0u8; 3];
        assert_eq!(
            state.copy_next_chunk(&mut out).unwrap(),
            StreamCopyResult::Copied {
                written: 3,
                has_more: true
            }
        );
        assert_eq!(&out, &[9, 8, 7]);
    }

    assert!(!path.exists(), "file-backed stream should remove temp file");
}
#[test]
fn test_stream_state_file_backed_delegates_fetch_copy_and_has_more() {
    let path = std::env::temp_dir().join(format!(
        "odbc_stream_state_delegate_{}.bin",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::write(&path, [9u8, 8, 7, 6, 5]).unwrap();

    let mut state =
        StreamState::FileBacked(StreamingStateFileBacked::new(path.clone(), 2, 5).unwrap());
    assert!(state.has_more());
    assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![9, 8]));
    let mut out = [0u8; 2];
    assert_eq!(
        state.copy_next_chunk(&mut out).unwrap(),
        StreamCopyResult::Copied {
            written: 2,
            has_more: true
        }
    );
    assert_eq!(&out, &[7, 6]);
    let mut last = [0u8; 1];
    assert_eq!(
        state.copy_next_chunk(&mut last).unwrap(),
        StreamCopyResult::Copied {
            written: 1,
            has_more: false
        }
    );
    assert_eq!(last[0], 5);
    assert_eq!(state.fetch_next_chunk().unwrap(), None);
}

#[test]
fn test_file_backed_streaming_state_copy_returns_end_when_exhausted() {
    let path = std::env::temp_dir().join(format!(
        "odbc_streaming_state_copy_end_{}.bin",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::write(&path, [1u8, 2]).unwrap();

    {
        let mut state = StreamingStateFileBacked::new(path.clone(), 4, 2).unwrap();
        state.offset = 2;
        let mut out = [0u8; 4];
        assert_eq!(
            state.copy_next_chunk(&mut out).unwrap(),
            StreamCopyResult::End
        );
        assert!(!state.has_more());
    }

    assert!(!path.exists());
}
#[test]
fn test_file_backed_total_len_matches_sum_of_chunk_reads() {
    let path = std::env::temp_dir().join(format!(
        "odbc_streaming_total_len_{}.bin",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let payload: Vec<u8> = (0u8..=20).collect();
    std::fs::write(&path, &payload).unwrap();

    {
        let mut state = StreamingStateFileBacked::new(path.clone(), 7, payload.len()).unwrap();
        let mut collected = Vec::new();
        while let Some(chunk) = state.fetch_next_chunk().unwrap() {
            collected.extend_from_slice(&chunk);
        }
        assert_eq!(collected, payload);
        assert_eq!(state.offset, payload.len());
    }

    assert!(!path.exists());
}
#[test]
fn test_stream_state_file_backed_has_more_delegates_until_exhausted() {
    let path = std::env::temp_dir().join(format!(
        "odbc_stream_state_has_more_{}.bin",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::write(&path, [1u8, 2, 3]).unwrap();

    {
        let mut state =
            StreamState::FileBacked(StreamingStateFileBacked::new(path.clone(), 2, 3).unwrap());
        assert!(state.has_more());
        assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![1, 2]));
        assert!(state.has_more());
        assert_eq!(state.fetch_next_chunk().unwrap(), Some(vec![3]));
        assert!(!state.has_more());
        assert_eq!(state.fetch_next_chunk().unwrap(), None);
    }

    assert!(!path.exists());
}
#[test]
fn test_file_backed_fetch_returns_none_when_offset_already_at_total() {
    let path = std::env::temp_dir().join(format!(
        "odbc_streaming_offset_past_{}.bin",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::write(&path, [1u8]).unwrap();

    {
        let mut state = StreamingStateFileBacked::new(path.clone(), 8, 1).unwrap();
        state.offset = 1;
        assert_eq!(state.fetch_next_chunk().unwrap(), None);
        assert!(!state.has_more());
    }

    assert!(!path.exists());
}

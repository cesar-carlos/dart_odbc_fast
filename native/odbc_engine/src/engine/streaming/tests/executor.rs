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
fn test_streaming_executor_new() {
    let executor = StreamingExecutor::new(1024);
    assert_eq!(executor.chunk_size(), 1024);
}
#[test]
fn test_streaming_executor_new_with_different_chunk_size() {
    let executor = StreamingExecutor::new(512);
    assert_eq!(executor.chunk_size(), 512);
}

use super::super::chunk::StreamCopyResult;
use super::super::columns::encode_row_buffer_with_encoding;
use super::super::multi_result::{
    frame_item, MULTI_STREAM_ITEM_TAG_RESULT_SET, MULTI_STREAM_ITEM_TAG_RESULT_SET_BATCH,
    MULTI_STREAM_ITEM_TAG_ROW_COUNT,
};
use super::super::state::{
    AsyncStreamStatus, AsyncStreamingState, BatchedMessage, BatchedStreamingState, StreamState,
    StreamingState, StreamingStateFileBacked,
};
use super::super::worker::StreamingExecutor;
use crate::engine::core::{DiskSpillStream, DiskSpillWriter, SpillReadSource};
use crate::engine::query::ResultEncoding;
use crate::error::OdbcError;
use crate::protocol::{OdbcType, RowBuffer, RowBufferEncoder};
use std::io::Write;
use std::sync::atomic::Ordering;
use std::sync::mpsc;

#[test]
fn test_encode_row_buffer_matches_row_buffer_encoder() {
    let mut buffer = RowBuffer::new();
    buffer.add_column("n".to_string(), OdbcType::Integer);
    buffer.add_row(vec![Some(7i32.to_le_bytes().to_vec())]);
    let via_helper = encode_row_buffer_with_encoding(&buffer, ResultEncoding::RowMajor).unwrap();
    let direct = RowBufferEncoder::encode(&buffer).unwrap();
    assert_eq!(via_helper, direct);
}
#[test]
fn test_encode_row_buffer_surfaces_resource_limit() {
    let mut buffer = RowBuffer::new();
    buffer.add_column("x".repeat(usize::from(u16::MAX) + 1), OdbcType::Varchar);
    let err = encode_row_buffer_with_encoding(&buffer, ResultEncoding::RowMajor).unwrap_err();
    assert!(matches!(err, OdbcError::ResourceLimitReached(_)));
    assert!(err.to_string().contains("encoding"));
}
#[test]
fn test_encode_row_buffer_empty_schema_succeeds() {
    let buffer = RowBuffer::new();
    let encoded = encode_row_buffer_with_encoding(&buffer, ResultEncoding::RowMajor).unwrap();
    assert_eq!(encoded, RowBufferEncoder::encode(&buffer).unwrap());
}
#[test]
fn test_encode_row_buffer_with_columnar_encoding_emits_v2_magic() {
    let mut buffer = RowBuffer::new();
    buffer.add_column("n".to_string(), OdbcType::Integer);
    buffer.add_row(vec![Some(7i32.to_le_bytes().to_vec())]);
    let encoded = encode_row_buffer_with_encoding(&buffer, ResultEncoding::Columnar).unwrap();
    let magic = u32::from_le_bytes(encoded[0..4].try_into().unwrap());
    assert_eq!(magic, 0x4F44_4243, "columnar v2 magic ODBC");
}

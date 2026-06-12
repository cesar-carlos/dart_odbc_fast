use super::super::chunk::StreamCopyResult;
use super::super::columns::encode_row_buffer;
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

use super::support::parse_multi_stream_frame;

#[test]
fn test_frame_item_encodes_payload_header() {
    let framed = frame_item(MULTI_STREAM_ITEM_TAG_RESULT_SET, vec![1, 2, 3]).unwrap();

    assert_eq!(framed[0], MULTI_STREAM_ITEM_TAG_RESULT_SET);
    assert_eq!(
        u32::from_le_bytes([framed[1], framed[2], framed[3], framed[4]]),
        3
    );
    assert_eq!(&framed[5..], &[1, 2, 3]);
}
#[test]
fn test_frame_item_row_count_tag_encodes_i64_payload() {
    let framed = frame_item(
        MULTI_STREAM_ITEM_TAG_ROW_COUNT,
        42i64.to_le_bytes().to_vec(),
    )
    .unwrap();
    assert_eq!(framed[0], MULTI_STREAM_ITEM_TAG_ROW_COUNT);
    assert_eq!(
        u32::from_le_bytes([framed[1], framed[2], framed[3], framed[4]]),
        8
    );
    assert_eq!(i64::from_le_bytes(framed[5..13].try_into().unwrap()), 42);
}
#[test]
fn test_multi_stream_item_tags_are_distinct() {
    assert_ne!(
        MULTI_STREAM_ITEM_TAG_RESULT_SET,
        MULTI_STREAM_ITEM_TAG_ROW_COUNT
    );
    assert_eq!(MULTI_STREAM_ITEM_TAG_RESULT_SET, 0);
    assert_eq!(MULTI_STREAM_ITEM_TAG_ROW_COUNT, 1);
}
#[test]
fn test_frame_item_empty_payload() {
    let framed = frame_item(MULTI_STREAM_ITEM_TAG_ROW_COUNT, vec![]).unwrap();
    assert_eq!(framed, [MULTI_STREAM_ITEM_TAG_ROW_COUNT, 0, 0, 0, 0]);
}
#[test]
fn test_multi_stream_frames_parse_result_set_then_row_count() {
    let rs = frame_item(MULTI_STREAM_ITEM_TAG_RESULT_SET, vec![9, 8, 7]).unwrap();
    let rc = frame_item(MULTI_STREAM_ITEM_TAG_ROW_COUNT, 5i64.to_le_bytes().to_vec()).unwrap();

    let (tag1, payload1) = parse_multi_stream_frame(&rs);
    assert_eq!(tag1, MULTI_STREAM_ITEM_TAG_RESULT_SET);
    assert_eq!(payload1, vec![9, 8, 7]);

    let (tag2, payload2) = parse_multi_stream_frame(&rc);
    assert_eq!(tag2, MULTI_STREAM_ITEM_TAG_ROW_COUNT);
    assert_eq!(i64::from_le_bytes(payload2.try_into().unwrap()), 5);
}
#[test]
fn test_frame_item_max_u32_payload_length_header() {
    let payload = vec![0u8; 1024];
    let framed = frame_item(MULTI_STREAM_ITEM_TAG_RESULT_SET, payload.clone()).unwrap();
    assert_eq!(
        u32::from_le_bytes([framed[1], framed[2], framed[3], framed[4]]),
        1024
    );
    assert_eq!(&framed[5..], &payload[..]);
}
#[test]
fn test_multi_stream_concatenated_frames_parse_in_order() {
    let rs = frame_item(MULTI_STREAM_ITEM_TAG_RESULT_SET, vec![1, 2]).unwrap();
    let rc = frame_item(MULTI_STREAM_ITEM_TAG_ROW_COUNT, 3i64.to_le_bytes().to_vec()).unwrap();
    let rs_len = rs.len();
    let mut combined = rs;
    combined.extend(rc);
    let (tag1, p1) = parse_multi_stream_frame(&combined[..rs_len]);
    assert_eq!(tag1, MULTI_STREAM_ITEM_TAG_RESULT_SET);
    assert_eq!(p1, vec![1, 2]);

    let (tag2, p2) = parse_multi_stream_frame(&combined[rs_len..]);
    assert_eq!(tag2, MULTI_STREAM_ITEM_TAG_ROW_COUNT);
    assert_eq!(i64::from_le_bytes(p2.try_into().unwrap()), 3);
}
#[test]
fn test_frame_item_capacity_is_tag_plus_len_plus_payload() {
    let payload = vec![4u8, 5, 6];
    let framed = frame_item(MULTI_STREAM_ITEM_TAG_RESULT_SET, payload.clone()).unwrap();
    assert_eq!(framed.len(), 5 + payload.len());
    assert_eq!(framed.capacity(), framed.len());
}

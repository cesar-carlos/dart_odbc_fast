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

#[test]
fn test_streaming_spill_writer_matches_row_buffer_encoder() {
    let mut buffer = RowBuffer::new();
    buffer.add_column("id".to_string(), OdbcType::Integer);
    buffer.add_column("name".to_string(), OdbcType::Varchar);
    buffer.add_row(vec![
        Some(1i32.to_le_bytes().to_vec()),
        Some(b"one".to_vec()),
    ]);
    buffer.add_row(vec![Some(2i32.to_le_bytes().to_vec()), None]);

    let expected = RowBufferEncoder::encode(&buffer).unwrap();
    let mut spill = DiskSpillStream::new(1);
    {
        let mut writer = DiskSpillWriter::new(&mut spill);
        RowBufferEncoder::encode_to_writer(&buffer, &mut writer).unwrap();
        writer.flush().unwrap();
    }
    let actual = spill.read_back().unwrap();

    assert_eq!(actual, expected);
}
#[test]
fn test_streaming_spill_threshold_file_backed_matches_encoder() {
    let mut buffer = RowBuffer::new();
    buffer.add_column("payload".to_string(), OdbcType::Binary);
    buffer.add_row(vec![Some(vec![42u8; 1024 * 1024 + 128])]);

    let expected = RowBufferEncoder::encode(&buffer).unwrap();
    let mut spill = DiskSpillStream::new(1);
    {
        let mut writer = DiskSpillWriter::new(&mut spill);
        RowBufferEncoder::encode_to_writer(&buffer, &mut writer).unwrap();
        writer.flush().unwrap();
    }

    let source = spill.finish_for_streaming_read().unwrap();
    let actual = match source {
        crate::engine::core::SpillReadSource::File(path) => {
            let bytes = std::fs::read(&path).unwrap();
            let _ = std::fs::remove_file(path);
            bytes
        }
        crate::engine::core::SpillReadSource::Memory(bytes) => bytes,
    };

    assert_eq!(actual, expected);
    assert!(
        actual.len() > 1024 * 1024,
        "test must exercise the low-threshold spill path"
    );
}
#[test]
fn test_spill_memory_source_preserves_encoder_bytes_and_metadata() {
    let mut buffer = RowBuffer::new();
    buffer.add_column("id".to_string(), OdbcType::Integer);
    buffer.add_row(vec![Some(1i32.to_le_bytes().to_vec())]);
    let expected = RowBufferEncoder::encode(&buffer).unwrap();

    let mut spill = DiskSpillStream::new(64);
    {
        let mut writer = DiskSpillWriter::new(&mut spill);
        RowBufferEncoder::encode_to_writer(&buffer, &mut writer).unwrap();
        writer.flush().unwrap();
    }
    assert_eq!(spill.threshold_mb(), 64);

    match spill.finish_for_streaming_read().unwrap() {
        SpillReadSource::Memory(bytes) => {
            assert_eq!(bytes, expected);
            let state = StreamingState {
                data: bytes,
                offset: 0,
                chunk_size: 4,
            };
            assert_eq!(state.data.len(), expected.len());
            assert!(state.has_more());
        }
        SpillReadSource::File(path) => {
            let _ = std::fs::remove_file(path);
            panic!("small payload must stay in memory under a 64 MiB threshold");
        }
    }
}

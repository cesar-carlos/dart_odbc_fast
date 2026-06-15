//! Cursor/batch streaming and multi-result wire framing.
//!
//! Submodules:
//! - [`columns`]: shared column metadata for streaming cursors
//! - [`chunk`]: chunk copy/take helpers and [`StreamCopyResult`]
//! - [`worker`]: [`StreamingExecutor`] and background worker threads
//! - [`multi_result`]: multi-result ODBC drive + framed wire items
//! - [`state`]: consumer-facing stream state machines (memory/file-backed)

mod batched_fetch;
mod chunk;
mod columns;
mod multi_result;
mod state;
mod worker;

#[cfg(test)]
mod tests;

pub use chunk::StreamCopyResult;
pub use multi_result::{
    start_multi_async_stream, start_multi_async_stream_pooled, start_multi_batched_stream,
    start_multi_batched_stream_pooled, MULTI_STREAM_ITEM_TAG_RESULT_SET,
    MULTI_STREAM_ITEM_TAG_RESULT_SET_BATCH, MULTI_STREAM_ITEM_TAG_ROW_COUNT,
};
pub use state::{
    AsyncStreamStatus, AsyncStreamingState, BatchedStreamingState, StreamState, StreamingState,
};
pub use worker::StreamingExecutor;

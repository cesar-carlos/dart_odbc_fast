//! Streaming unit tests (split from the former monolithic `streaming/tests.rs`).

#![allow(
    unused_imports,
    dead_code,
    reason = "Topic-split test modules; trim per-file imports in ODBC-ENG-426 by 2026-09-30."
)]

mod support;

mod async_state;
mod batched;
mod encode;
mod executor;
mod file_backed;
mod in_memory;
mod multi_frame;
mod spill;

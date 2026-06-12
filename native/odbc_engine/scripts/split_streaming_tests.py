#!/usr/bin/env python3
"""Split engine/streaming/tests.rs into topic submodules."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "engine" / "streaming" / "tests.rs"
OUT = ROOT / "src" / "engine" / "streaming" / "tests"

IMPORTS = """use super::super::chunk::StreamCopyResult;
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
"""

MOD_RS = """//! Streaming unit tests (split from the former monolithic `streaming/tests.rs`).

mod support;

mod async_state;
mod batched;
mod encode;
mod file_backed;
mod in_memory;
mod multi_frame;
mod spill;
mod executor;
"""

SUPPORT = """use super::super::multi_result::{
    frame_item, MULTI_STREAM_ITEM_TAG_RESULT_SET, MULTI_STREAM_ITEM_TAG_ROW_COUNT,
};

pub(super) fn parse_multi_stream_frame(bytes: &[u8]) -> (u8, Vec<u8>) {
    assert!(bytes.len() >= 5, "frame must include tag + u32 len");
    let tag = bytes[0];
    let len = u32::from_le_bytes([bytes[1], bytes[2], bytes[3], bytes[4]]) as usize;
    assert_eq!(bytes.len(), 5 + len);
    (tag, bytes[5..].to_vec())
}
"""


def classify(name: str) -> str:
    lower = name.lower()
    if "batched" in lower:
        return "batched"
    if "async" in lower:
        return "async_state"
    if any(k in lower for k in ("file_backed", "spill", "disk")):
        if "spill" in lower or "disk" in lower:
            return "spill"
        return "file_backed"
    if any(k in lower for k in ("frame", "multi_stream")):
        return "multi_frame"
    if "encode_row" in lower:
        return "encode"
    if "streaming_executor" in lower or "executor" in lower:
        return "executor"
    return "in_memory"


def split_tests(text: str) -> dict[str, list[str]]:
    pattern = re.compile(r"(#\[test\]\s*\n(?:#\[.*?\]\s*\n)*fn test_\w+.*?(?=\n#\[test\]|\Z))", re.DOTALL)
    blocks: dict[str, list[str]] = {
        k: []
        for k in (
            "batched",
            "async_state",
            "file_backed",
            "multi_frame",
            "encode",
            "spill",
            "in_memory",
            "executor",
        )
    }
    for match in pattern.finditer(text):
        block = match.group(1).rstrip() + "\n"
        name_match = re.search(r"fn (test_\w+)", block)
        if not name_match:
            continue
        bucket = classify(name_match.group(1))
        blocks[bucket].append(block)
    return blocks


def main() -> None:
    text = SRC.read_text(encoding="utf-8")
    blocks = split_tests(text)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "mod.rs").write_text(MOD_RS, encoding="utf-8")
    (OUT / "support.rs").write_text(SUPPORT, encoding="utf-8")
    file_map = {
        "batched": "batched.rs",
        "async_state": "async_state.rs",
        "file_backed": "file_backed.rs",
        "multi_frame": "multi_frame.rs",
        "encode": "encode.rs",
        "spill": "spill.rs",
        "in_memory": "in_memory.rs",
        "executor": "executor.rs",
    }
    for key, filename in file_map.items():
        body = "".join(blocks[key])
        extra = ""
        if key == "multi_frame":
            extra = "use super::support::parse_multi_stream_frame;\n"
        (OUT / filename).write_text(f"{IMPORTS}\n{extra}\n{body}", encoding="utf-8")
    total = sum(len(v) for v in blocks.values())
    print(f"Wrote {total} tests across {len(file_map)} modules under {OUT}")


if __name__ == "__main__":
    main()

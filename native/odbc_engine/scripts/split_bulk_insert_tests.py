#!/usr/bin/env python3
"""Split protocol/bulk_insert/tests.rs into topic submodules."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "protocol" / "bulk_insert" / "tests.rs"
OUT = ROOT / "src" / "protocol" / "bulk_insert" / "tests"

IMPORTS = """use super::super::common::{
    BulkColumnType, BulkPayloadWire, BULK_V2_MAGIC, BULK_V2_VERSION, MAX_BULK_CELL_LEN,
    MAX_BULK_COLUMNS, MAX_BULK_ROWS, TAG_BINARY, TAG_I32, TAG_I64, TAG_TEXT,
};
use super::super::legacy::trim_legacy_nul_padded_cell;
use super::super::{
    estimate_serialized_payload_size, is_null, is_null_strict, null_bitmap_size,
    parse_bulk_insert_payload, serialize_bulk_insert_payload, serialize_bulk_insert_payload_v2,
    BulkColumnData, BulkColumnSpec, BulkInsertPayload, BulkTimestamp,
};
"""

MOD_RS = """//! Bulk insert unit tests (split from the former monolithic `bulk_insert/tests.rs`).

#![allow(
    unused_imports,
    dead_code,
    reason = "Topic-split test modules; trim per-file imports in ODBC-ENG-426 by 2026-09-30."
)]

mod column_types;
mod estimate;
mod legacy_wire;
mod null_bitmap;
mod roundtrip;
mod validation;
mod v2;
"""

FILE_MAP = {
    "roundtrip": "roundtrip.rs",
    "v2": "v2.rs",
    "legacy": "legacy_wire.rs",
    "null_bitmap": "null_bitmap.rs",
    "validation": "validation.rs",
    "common": "column_types.rs",
    "estimate": "estimate.rs",
}


def classify(name: str) -> str:
    lower = name.lower()
    if "null_bitmap" in lower or lower.startswith("is_null"):
        return "null_bitmap"
    if "estimate" in lower:
        return "estimate"
    if "legacy" in lower or "trim_legacy" in lower:
        return "legacy"
    if "v2" in lower or "blk2" in lower:
        return "v2"
    if "bulk_column_type" in lower or "tag_roundtrip" in lower:
        return "common"
    if "roundtrip" in lower or "parse_roundtrip" in lower:
        return "roundtrip"
    return "validation"


def split_tests(text: str) -> dict[str, list[str]]:
    pattern = re.compile(
        r"(#\[test\]\s*\n(?:#\[.*?\]\s*\n)*fn \w+.*?(?=\n#\[test\]|\Z))",
        re.DOTALL,
    )
    blocks: dict[str, list[str]] = {k: [] for k in FILE_MAP}
    for match in pattern.finditer(text):
        block = match.group(1).rstrip() + "\n"
        name_match = re.search(r"fn (\w+)", block)
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
    for key, filename in FILE_MAP.items():
        body = "".join(blocks[key])
        (OUT / filename).write_text(f"{IMPORTS}\n{body}", encoding="utf-8")
    total = sum(len(v) for v in blocks.values())
    print(f"Wrote {total} tests across {len(FILE_MAP)} modules under {OUT}")


if __name__ == "__main__":
    main()

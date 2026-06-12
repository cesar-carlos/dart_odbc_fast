#!/usr/bin/env python3
"""Split ffi/tests.rs into domain modules using name-based classification."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "ffi" / "tests.rs"
OUT = ROOT / "src" / "ffi" / "tests"

IMPORTS = """use crate::ffi::bulk::row_chunk_ranges;
#[cfg(feature = "sqlserver-bcp")]
use crate::ffi::bulk::slice_payload_rows;
use crate::ffi::connection::validate_connection_string_format;
use crate::ffi::global::*;
use crate::ffi::prelude::*;
use crate::ffi::state;
use crate::ffi::xa::xa_read_buffer;
use crate::ffi::*;
use crate::protocol::{
    serialize_bulk_insert_payload, serialize_bulk_insert_payload_v2, serialize_params,
    BulkColumnData, BulkColumnSpec, BulkColumnType, BulkInsertPayload, ParamValue,
};
use serde_json::Value;
use serial_test::serial;
use std::ffi::CString;
use std::os::raw::{c_char, c_int, c_uint};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Barrier, Mutex, OnceLock};
use std::time::Duration;

use super::support::{
    ffi_test_dsn, ffi_test_dsn_is_sql_server, get_last_error, next_test_invalid_id,
    structured_error_test_lock, trigger_structured_cancel_unsupported_error,
    with_structured_error_test_isolation, TEST_INVALID_ID,
};
"""

MOD_RS = """//! FFI unit tests (split from the former monolithic `ffi/tests.rs`).

mod support;

mod bulk;
mod core;
mod pool;
mod query;
mod stream;
mod transaction;
mod xa;
"""

SUPPORT_ITEMS = {
    "TEST_INVALID_ID_BASE",
    "TEST_INVALID_ID",
    "next_test_invalid_id",
    "get_last_error",
    "trigger_structured_cancel_unsupported_error",
    "structured_error_test_lock",
    "with_structured_error_test_isolation",
    "ffi_test_dsn",
    "ffi_test_dsn_is_sql_server",
    "release_pooled_connection_with_retry",
    "fetch_and_close_stream",
    "run_pooled_stream_case",
}


def classify(name: str) -> str:
    lower = name.lower()
    if "bulk" in lower:
        return "bulk"
    if "pool" in lower:
        return "pool"
    if "xa" in lower:
        return "xa"
    if "stream" in lower:
        return "stream"
    if "transaction" in lower or "savepoint" in lower:
        return "transaction"
    if any(
        token in lower
        for token in (
            "exec_query",
            "execute_async",
            "async_",
            "prepare",
            "statement",
            "cancel",
            "odbc_get_metrics",
            "timeout_override",
            "execute_retry",
        )
    ):
        return "query"
    return "core"


def find_block_end(lines: list[str], start: int) -> int:
    depth = 0
    started = False
    for i in range(start, len(lines)):
        line = lines[i]
        in_str = False
        escape = False
        for ch in line:
            if in_str:
                if escape:
                    escape = False
                elif ch == "\\":
                    escape = True
                elif ch == '"':
                    in_str = False
                continue
            if ch == '"':
                in_str = True
            elif ch == "{":
                depth += 1
                started = True
            elif ch == "}":
                depth -= 1
                if started and depth == 0:
                    return i + 1
    raise RuntimeError(f"unclosed block from line {start + 1}")


def item_name(line: str) -> str | None:
    stripped = line.strip()
    for prefix in ("const ", "fn "):
        if stripped.startswith(prefix):
            m = re.match(rf"{prefix}(\w+)", stripped)
            if m:
                return m.group(1)
    return None


def is_test_fn(lines: list[str], fn_idx: int) -> bool:
    for j in range(max(0, fn_idx - 4), fn_idx):
        if lines[j].strip().startswith("#[test"):
            return True
    return False


def is_test_start(lines: list[str], idx: int) -> bool:
    if not lines[idx].strip().startswith("#[test"):
        return False
    j = idx + 1
    while j < len(lines) and lines[j].strip().startswith("#["):
        j += 1
    return j < len(lines) and lines[j].strip().startswith("fn ")


def test_name(lines: list[str], idx: int) -> str:
    j = idx + 1
    while j < len(lines) and not lines[j].strip().startswith("fn "):
        j += 1
    m = re.match(r"fn\s+(\w+)", lines[j].strip())
    if not m:
        raise RuntimeError(f"missing fn at line {j + 1}")
    return m.group(1)


def main() -> None:
    if not SRC.exists():
        raise SystemExit(f"missing {SRC}")

    lines = SRC.read_text(encoding="utf-8").splitlines(keepends=True)
    support_chunks: list[str] = []
    grouped: dict[str, list[str]] = {k: [] for k in ("core", "query", "stream", "transaction", "pool", "bulk", "xa")}

    i = 0
    while i < len(lines) and not (
        item_name(lines[i]) in SUPPORT_ITEMS or is_test_start(lines, i)
    ):
        i += 1

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        name = item_name(line)
        if (
            name
            and stripped.startswith(("const ", "fn "))
            and not is_test_fn(lines, i)
        ):
            end = find_block_end(lines, i)
            chunk = "".join(lines[i:end]) + "\n"
            if name.startswith("TEST_INVALID"):
                chunk = chunk.replace(f"const {name}", f"pub(crate) const {name}")
            else:
                chunk = chunk.replace(f"fn {name}", f"pub(crate) fn {name}")
            support_chunks.append(chunk)
            i = end
            continue

        if is_test_start(lines, i):
            name = test_name(lines, i)
            j = i + 1
            while j < len(lines) and not lines[j].strip().startswith("fn "):
                j += 1
            end = find_block_end(lines, j)
            grouped[classify(name)].extend(lines[i:end])
            grouped[classify(name)].append("\n")
            i = end
            continue

        if stripped == "" or stripped.startswith("//"):
            i += 1
            continue

        raise RuntimeError(f"unhandled line {i + 1}: {line!r}")

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "mod.rs").write_text(MOD_RS, encoding="utf-8")

    support_header = """//! Shared helpers for FFI unit tests.

use crate::ffi::global::*;
use crate::ffi::prelude::*;
use crate::ffi::state;
use crate::ffi::*;
use std::ffi::CString;
use std::os::raw::{c_char, c_uint};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

"""
    (OUT / "support.rs").write_text(support_header + "".join(support_chunks), encoding="utf-8")

    for module, chunks in grouped.items():
        content = f"//! FFI `{module}` tests.\n\n#![allow(unused_imports)]\n\n{IMPORTS}\n" + "".join(
            chunks
        )
        (OUT / f"{module}.rs").write_text(content, encoding="utf-8")

    SRC.unlink()
    total = sum("".join(c).count("#[test") for c in grouped.values())
    print(f"split {total} tests into {OUT}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Split ffi/tests/core.rs into topic submodules."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "ffi" / "tests" / "core.rs"
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
mod catalog;
mod connection;
mod diagnostics;
mod errors;
mod init;
mod pool;
mod query;
mod stream;
mod transaction;
mod xa;
"""

FILE_MAP = {
    "init": "init.rs",
    "diagnostics": "diagnostics.rs",
    "connection": "connection.rs",
    "catalog": "catalog.rs",
    "errors": "errors.rs",
}


def classify(name: str) -> str:
    lower = name.lower()
    if "audit" in lower:
        return "diagnostics"
    if "catalog" in lower or "catalog_cache" in lower:
        return "catalog"
    if any(
        token in lower
        for token in (
            "structured_error",
            "get_error",
            "global_error",
            "connection_error",
            "connection_errors",
        )
    ):
        return "errors"
    if any(
        token in lower
        for token in (
            "connect",
            "disconnect",
            "lifecycle",
            "connection_string",
            "validate_connection",
            "ptr_to_opt",
            "param_buffer",
            "upsert",
            "returning_sql",
            "sync_param_ffi",
        )
    ):
        return "connection"
    if "out_written" in lower and "metadata_cache" not in lower:
        return "connection"
    return "init"


def split_tests(text: str) -> dict[str, list[str]]:
    pattern = re.compile(
        r"(#\[test\]\s*\n(?:#\[.*?\]\s*\n)*(?:///.*\n)*fn \w+.*?(?=\n(?:#\[test\]|// -{3,}|\Z)))",
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
    if not SRC.exists():
        raise SystemExit(f"missing {SRC}")

    text = SRC.read_text(encoding="utf-8")
    blocks = split_tests(text)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "mod.rs").write_text(MOD_RS, encoding="utf-8")

    for key, filename in FILE_MAP.items():
        content = (
            f"//! FFI `core::{key}` tests.\n\n"
            f"#![allow(unused_imports)]\n\n{IMPORTS}\n"
            + "".join(blocks[key])
        )
        (OUT / filename).write_text(content, encoding="utf-8")

    SRC.unlink()
    total = sum(len(blocks[k]) for k in FILE_MAP)
    print(f"split {total} tests from core.rs into {OUT}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Split engine/transaction/tests.rs into topic submodules."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "engine" / "transaction" / "tests.rs"
OUT = ROOT / "src" / "engine" / "transaction" / "tests"

IMPORTS = """use super::super::{
    savepoint::quoting_for, IsolationLevel, LockTimeout, SavepointDialect, Transaction,
    TransactionAccessMode, TransactionState,
};
use crate::engine::identifier::{quote_identifier, validate_identifier};
use crate::error::OdbcError;
use crate::handles::{HandleManager, SharedHandleManager};
use std::sync::{Arc, Mutex};
use std::time::Duration;
"""

MOD_RS = """//! Transaction unit tests (split from the former monolithic `transaction/tests.rs`).

#![allow(
    unused_imports,
    dead_code,
    reason = "Topic-split test modules; trim per-file imports in ODBC-ENG-426 by 2026-09-30."
)]

mod access_mode;
mod isolation;
mod lock_timeout;
mod savepoint;
mod state;
"""

FILE_MAP = {
    "isolation": "isolation.rs",
    "state": "state.rs",
    "savepoint": "savepoint.rs",
    "access_mode": "access_mode.rs",
    "lock_timeout": "lock_timeout.rs",
}


def classify(name: str) -> str:
    lower = name.lower()
    if "lock_timeout" in lower:
        return "lock_timeout"
    if "access_mode" in lower:
        return "access_mode"
    if "savepoint" in lower or "quoting_for" in lower or "resolve_savepoint" in lower:
        return "savepoint"
    if "isolation" in lower:
        return "isolation"
    return "state"


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

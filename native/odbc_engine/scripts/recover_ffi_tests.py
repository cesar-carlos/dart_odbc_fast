#!/usr/bin/env python3
"""Recover ffi/tests.rs from committed ffi/mod.rs inline test module."""

from __future__ import annotations

import re
import subprocess
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "src" / "ffi" / "tests.rs"
REPO = ROOT.parents[1]

HEADER = """//! FFI unit tests (moved from the former monolithic `ffi/mod.rs`).

use super::bulk::row_chunk_ranges;
#[cfg(feature = "sqlserver-bcp")]
use super::bulk::slice_payload_rows;
use super::connection::validate_connection_string_format;
use super::global::*;
use super::prelude::*;
use super::state;
use super::xa::xa_read_buffer;
use super::*;
use std::sync::atomic::AtomicBool;
"""


def main() -> None:
    text = subprocess.check_output(
        ["git", "show", "HEAD:native/odbc_engine/src/ffi/mod.rs"],
        cwd=REPO,
    ).decode("utf-8")
    lines = text.splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "#[cfg(test)]")
    if lines[start + 1].strip() != "mod tests {":
        raise RuntimeError("Expected `mod tests {` after #[cfg(test)]")
    body_lines = lines[start + 2 :]
    if body_lines[-1].strip() != "}":
        raise RuntimeError("Expected closing `}` for mod tests at EOF")
    body_lines = body_lines[:-1]
    body = textwrap.dedent("\n".join(body_lines)).strip() + "\n"
    body = re.sub(r"^use super::\*;\n", "", body, count=1, flags=re.MULTILINE)
    OUT.write_text(HEADER + body, encoding="utf-8")
    print(f"Wrote {OUT} ({OUT.read_text(encoding='utf-8').count(chr(10))} lines)")


if __name__ == "__main__":
    main()

"""Regenerate native_odbc_connection part files from HEAD."""

from __future__ import annotations

import subprocess
from pathlib import Path

orig = subprocess.check_output(
    [
        "git",
        "show",
        "HEAD:lib/infrastructure/native/native_odbc_connection.dart",
    ],
    text=True,
)
lines = orig.splitlines(keepends=True)

sections = [
    ("native_connection.dart", "_NativeConnection", 55, 169),
    ("native_async_audit.dart", "_NativeAsyncAudit", 170, 276),
    ("native_transactions.dart", "_NativeTransactions", 278, 460),
    ("native_prepared_query.dart", "_NativePreparedQuery", 461, 675),
    ("native_catalog.dart", "_NativeCatalog", 676, 714),
    ("native_pool.dart", "_NativePool", 715, 831),
    ("native_streaming.dart", "_NativeStreaming", 832, 1014),
]

base = Path("lib/infrastructure/native")
for fname, mixin, start, end in sections:
    chunk = lines[start : end + 1]
    body = "".join(chunk)
    content = (
        "part of 'native_odbc_connection.dart';\n\n"
        f"mixin {mixin} on _NativeOdbcState {{\n"
        f"{body}"
        "}\n"
    )
    out = base / fname
    out.write_text(content, encoding="utf-8", newline="\n")
    print(f"{fname}: {end - start + 1} lines")

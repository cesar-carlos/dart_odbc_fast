#!/usr/bin/env python3
"""One-shot script to split odbc_bindings.dart into part files."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINDINGS_DIR = ROOT / "lib/infrastructure/native/bindings"
SOURCE = BINDINGS_DIR / "odbc_bindings.dart"

DOMAINS = ("connection", "query", "stream", "transaction", "xa", "pool")

DOMAIN_PREFIXES: dict[str, list[str]] = {
    "connection": [
        "odbc_init",
        "odbc_set_log_level",
        "odbc_get_version",
        "odbc_validate_connection_string",
        "odbc_connect",
        "odbc_disconnect",
        "odbc_get_error",
        "odbc_get_structured_error",
        "odbc_detect_driver",
        "odbc_get_driver_capabilities",
        "odbc_get_connection_dbms_info",
        "odbc_build_upsert_sql",
        "odbc_append_returning_sql",
        "odbc_get_session_init_sql",
        "odbc_audit_",
        "odbc_metadata_cache_",
        "supportsAuditApi",
        "supportsDriverCapabilitiesApi",
        "supportsConnectionDbmsInfoApi",
        "supportsCapabilitiesApi",
        "supportsMetadataCacheApi",
        "supportsStructuredErrorForConnection",
    ],
    "query": [
        "odbc_exec_query",
        "odbc_execute_async",
        "odbc_async_",
        "odbc_get_metrics",
        "odbc_get_cache_metrics",
        "odbc_clear_statement_cache",
        "odbc_catalog_",
        "odbc_prepare",
        "odbc_execute",
        "odbc_cancel",
        "odbc_close_statement",
        "odbc_clear_all_statements",
        "odbc_bulk_insert_",
        "supportsExecQueryMultiParams",
        "supportsExecQueryParamsOptions",
        "supportsAsyncExecuteApi",
        "supportsAsyncExecuteParamsApi",
        "supportsAsyncExecuteParamsOptionsApi",
    ],
    "stream": [
        "odbc_stream_",
        "supportsAsyncStreamApi",
        "supportsMultiResultStream",
        "supportsAsyncMultiResultStream",
    ],
    "transaction": [
        "odbc_transaction_",
        "odbc_savepoint_",
        "supportsTransactionAccessMode",
        "supportsTransactionLockTimeout",
    ],
    "xa": [
        "odbc_xa_",
        "_xaUnsupported",
        "supportsXa",
    ],
    "pool": [
        "odbc_pool_",
        "supportsPoolCreateWithOptions",
    ],
}


def classify(text: str) -> str:
    for domain, prefixes in DOMAIN_PREFIXES.items():
        for prefix in prefixes:
            if prefix in text:
                return domain
    raise ValueError(f"Unclassified block:\n{text[:200]}")


def main() -> None:
    content = SOURCE.read_text(encoding="utf-8")
    typedef_start = content.index("typedef odbc_init_func")
    types_section = content[typedef_start:]

    constructor_start = content.index("OdbcBindings(this._dylib) {")
    constructor_end = content.index("  }\n  final ffi.DynamicLibrary _dylib;")
    constructor_lines = content[constructor_start:constructor_end].split("\n")

    body = content[constructor_end + len("  }\n  final ffi.DynamicLibrary _dylib;") : typedef_start]
    body = body.strip()
    if body.endswith("}"):
        body = body[:-1].rstrip()

    ctor_blocks: dict[str, list[str]] = {
        d: [f"  void _bind{d.title()}() {{"] for d in DOMAINS
    }

    i = 1
    while i < len(constructor_lines):
        line = constructor_lines[i]
        if not line.strip():
            i += 1
            continue

        block: list[str] = []
        if line.strip().startswith("try {"):
            depth = 0
            while i < len(constructor_lines):
                block.append(constructor_lines[i])
                depth += constructor_lines[i].count("{") - constructor_lines[i].count(
                    "}"
                )
                i += 1
                if depth <= 0:
                    break
            if i < len(constructor_lines) and "on Object catch" in constructor_lines[i]:
                while i < len(constructor_lines):
                    block.append(constructor_lines[i])
                    if constructor_lines[i].strip() == "}":
                        i += 1
                        break
                    i += 1
        else:
            block.append(line)
            i += 1

        domain = classify("\n".join(block))
        ctor_blocks[domain].extend(block)

    for domain in DOMAINS:
        ctor_blocks[domain].append("  }")

    chunks: list[str] = []
    current: list[str] = []
    starts_member = re.compile(
        r"^  (late |ffi\.Pointer|bool get |int odbc|int\? odbc|UnsupportedError _xa)"
    )

    for line in body.split("\n"):
        if starts_member.match(line) and current:
            chunks.append("\n".join(current).rstrip())
            current = [line]
        else:
            current.append(line)
    if current:
        chunks.append("\n".join(current).rstrip())

    domain_chunks: dict[str, list[str]] = {d: [] for d in DOMAINS}
    for chunk in chunks:
        domain_chunks[classify(chunk)].append(chunk)

    header = """// FFI bindings must match native C/Rust symbol names exactly.
// ignore_for_file: non_constant_identifier_names, camel_case_types,
// lines_longer_than_80_chars

library;

import 'dart:ffi' as ffi;

part 'odbc_bindings_connection.dart';
part 'odbc_bindings_query.dart';
part 'odbc_bindings_stream.dart';
part 'odbc_bindings_transaction.dart';
part 'odbc_bindings_xa.dart';
part 'odbc_bindings_pool.dart';
part 'odbc_bindings_types.dart';

/// Shared native library handle for [OdbcBindings] mixins.
abstract class _OdbcBindingsState {
  _OdbcBindingsState(this._dylib);

  final ffi.DynamicLibrary _dylib;
}

/// Low-level FFI bindings for the native ODBC engine.
class OdbcBindings extends _OdbcBindingsState
    with
        _OdbcBindingsConnection,
        _OdbcBindingsQuery,
        _OdbcBindingsStream,
        _OdbcBindingsTransaction,
        _OdbcBindingsXa,
        _OdbcBindingsPool {
  OdbcBindings(super._dylib) {
    _bindConnection();
    _bindQuery();
    _bindStream();
    _bindTransaction();
    _bindXa();
    _bindPool();
  }
}
"""

    SOURCE.write_text(header, encoding="utf-8")

    mixin_names = {
        "connection": "_OdbcBindingsConnection",
        "query": "_OdbcBindingsQuery",
        "stream": "_OdbcBindingsStream",
        "transaction": "_OdbcBindingsTransaction",
        "xa": "_OdbcBindingsXa",
        "pool": "_OdbcBindingsPool",
    }

    for domain in DOMAINS:
        mixin = mixin_names[domain]
        part_body = "\n\n".join([ctor_blocks[domain][0]] + ctor_blocks[domain][1:-1])
        # fix: ctor_blocks already has open/close - rebuild properly
        bind_method = "\n".join(ctor_blocks[domain])
        members = "\n\n".join(domain_chunks[domain])
        part_content = f"""part of 'odbc_bindings.dart';

mixin {mixin} on _OdbcBindingsState {{
{bind_method}

{members}
}}
"""
        (BINDINGS_DIR / f"odbc_bindings_{domain}.dart").write_text(
            part_content, encoding="utf-8"
        )

    types_content = f"""part of 'odbc_bindings.dart';

{types_section.strip()}
"""
    (BINDINGS_DIR / "odbc_bindings_types.dart").write_text(
        types_content, encoding="utf-8"
    )

    print("Split complete.")


if __name__ == "__main__":
    main()

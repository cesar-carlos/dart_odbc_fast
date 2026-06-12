#!/usr/bin/env python3
"""Generate query/stream/admin runners from odbc_repository_impl.dart."""

from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
ORIGINAL = ROOT / "tool/odbc_repository_impl_original.dart"
OUT = ROOT / "lib/infrastructure/repositories/runners"

REPL = [
    (r"\b_connectionIds\b", "state.connectionIds"),
    (r"\b_connectionOptions\b", "state.connectionOptions"),
    (r"\b_connectionStrings\b", "state.connectionStrings"),
    (r"\b_namedParamOrderByStmtId\b", "state.namedParamOrderByStmtId"),
    (r"\b_statementConnectionByStmtId\b", "state.statementConnectionByStmtId"),
    (r"\b_clearAllStatementMetadata\b", "state.clearAllStatementMetadata"),
    (r"\b_optionsFor\b", "state.optionsFor"),
    (r"\b_validateStatementOwnership\b", "state.validateStatementOwnership"),
    (r"\b_isAsync\b", "ffi.isAsync"),
    (r"\b_async\b", "ffi.async"),
    (r"\b_sync\b", "ffi.sync"),
    (r"\b_runBoolFfi\b", "ffi.runBoolFfi"),
    (r"\b_runBoolFfiWithCleanup\b", "ffi.runBoolFfiWithCleanup"),
    (r"\b_runIntFfi\b", "ffi.runIntFfi"),
    (r"\b_convertNativeErrorToFailure\b", "ffi.convertNativeErrorToFailure"),
    (r"\b_getStructuredNativeError\b", "ffi.getStructuredNativeError"),
    (r"\b_parseBufferToQueryResult\b", "parser.parseBufferToQueryResult"),
    (r"\b_toQueryResult\b", "parser.toQueryResult"),
    (r"\b_toQueryResultMulti\b", "parser.toQueryResultMulti"),
    (r"\b_toQueryResultMultiItem\b", "parser.toQueryResultMultiItem"),
    (r"\b_queryErrorFactory\b", "odbcQueryErrorFactory"),
    (r"\b_connectionErrorFactory\b", "odbcConnectionErrorFactory"),
    (r"\b_queryTimedOutMessage\b", "odbcQueryTimedOutMessage"),
    (r"\b_streamProtocolErrorPrefix\b", "odbcStreamProtocolErrorPrefix"),
    (r"\b_streamInterruptedPrefix\b", "odbcStreamInterruptedPrefix"),
    (r"\b_isUnsupportedCancellation\b", "isUnsupportedCancellation"),
    (r"\b_withReconnect\b", "connection.withReconnect"),
    (r"\b_toParamValues\b", "_toParamValues"),
    (r"\b_backend\b", "ffi.backend"),
]

QUERY_IMPORTS = '''import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart'
    show MultiResultParser;
import 'package:odbc_fast/infrastructure/native/protocol/named_parameter_parser.dart'
    show NamedParameterParser, ParameterMissingException;
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_connection_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:result_dart/result_dart.dart';
'''

STREAM_IMPORTS = '''import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart'
    show MultiResultItem;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart'
    show MultiResultStreamDecoder;
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_connection_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_query_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:result_dart/result_dart.dart';
'''

ADMIN_IMPORTS = '''import 'dart:convert';

import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart'
    show AsyncWorkerPoolStats;
import 'package:odbc_fast/infrastructure/native/driver_capabilities.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:result_dart/result_dart.dart';
'''


def transform(body: str, extra: list[tuple[str, str]] | None = None) -> str:
    for a, b in REPL + (extra or []):
        body = re.sub(a, b, body)
    return body


def extract_method(text: str, name: str) -> str | None:
    lines = text.splitlines(keepends=True)
    start_idx = None
    for i, line in enumerate(lines):
        if re.search(rf"\b{re.escape(name)}\s*\(", line) and line.startswith("  "):
            if line.lstrip().startswith("@") or line.lstrip().startswith("//"):
                continue
            if re.match(
                r"  (?:Future|Stream|bool|void|DartSideMetrics|String\?|QueryResult|List<)",
                line,
            ) or (name.startswith("_") and f" {name}(" in line):
                start_idx = i
                break
    if start_idx is None:
        for i, line in enumerate(lines):
            if re.search(rf"\b{re.escape(name)}\s*\(", line):
                start_idx = i
                break
    if start_idx is None:
        return None

    # Include leading @override / @Deprecated block
    while start_idx > 0 and (
        lines[start_idx - 1].strip().startswith("@")
        or lines[start_idx - 1].strip() == ")"
        or (
            lines[start_idx - 1].strip().startswith("'")
            and "Deprecated" in "".join(lines[max(0, start_idx - 4) : start_idx])
        )
    ):
        start_idx -= 1

    chunk = "".join(lines[start_idx:])
    if "=>" in lines[start_idx] and "{" not in lines[start_idx]:
        end = chunk.find(";") + 1
        return chunk[:end]

    body_open = re.search(
        r"\)\s*(?:async\s*)?(?:\*\s*)?(?:=>|\{)",
        chunk,
    )
    if not body_open:
        return None
    if chunk[body_open.end() - 1] != "{":
        end = chunk.find(";", body_open.end()) + 1
        return chunk[:end]
    i = body_open.end() - 1
    depth = 0
    for j in range(i, len(chunk)):
        if chunk[j] == "{":
            depth += 1
        elif chunk[j] == "}":
            depth -= 1
            if depth == 0:
                return chunk[: j + 1]
    return None


def dedent_method(method: str) -> str:
    lines = []
    skip_deprecated_orphan = False
    for line in method.splitlines():
        stripped = line.strip()
        if stripped == "@override":
            continue
        if stripped.startswith("@Deprecated"):
            skip_deprecated_orphan = True
            continue
        if skip_deprecated_orphan:
            if stripped in (")", ") async {", ") {"):
                skip_deprecated_orphan = False
            continue
        if line.startswith("  "):
            lines.append("  " + line[2:])
        else:
            lines.append(line)
    return "\n".join(lines)


def build_runner(
    class_name: str,
    doc: str,
    fields: str,
    methods: list[str],
    imports: str,
    src: str,
    extra_repl: list[tuple[str, str]] | None = None,
) -> str:
    parts = []
    missing = []
    for name in methods:
        m = extract_method(src, name)
        if m is None:
            missing.append(name)
            continue
        parts.append(dedent_method(transform(m, extra_repl)))
    if missing:
        raise SystemExit(f"{class_name} missing methods: {missing}")
    body = "\n\n".join(parts)
    return f"""{imports}

/// {doc}
class {class_name} {{
{fields}

{body}
}}
"""


def main() -> None:
    src = ORIGINAL.read_text(encoding="utf-8")

    query = build_runner(
        "OdbcQueryRunner",
        "Query execution and prepared-statement operations.",
        """  OdbcQueryRunner({
    required this.ffi,
    required this.state,
    required this.connection,
    required this.parser,
  });

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;
  final OdbcConnectionRunner connection;
  final OdbcResultParser parser;
  late StreamNativeQueryFn streamNativeQueryWithFallback;
  late StreamingFailureFn streamingFailureFromException;""",
        [
            "executeQuery",
            "executeQueryParams",
            "executeQueryParamBuffer",
            "executeQueryNamed",
            "executeQueryMulti",
            "executeQueryMultiFull",
            "executeQueryMultiParams",
            "prepare",
            "prepareNamed",
            "executePrepared",
            "executePreparedNamed",
            "closeStatement",
            "cancelStatement",
            "clearStatementCache",
            "clearAllStatements",
            "getPreparedStatementsMetrics",
            "_toParamValues",
        ],
        QUERY_IMPORTS,
        src,
    )
    query = query.replace(
        "_streamingFailureFromException",
        "streamingFailureFromException",
    )
    query = query.replace(
        "_streamNativeQueryWithFallback",
        "streamNativeQueryWithFallback",
    )
    query = query.replace(
        "import 'package:odbc_fast/domain/entities/statement_options.dart';\n",
        "import 'package:odbc_fast/domain/entities/odbc_metrics.dart';\n"
        "import 'package:odbc_fast/domain/entities/statement_options.dart';\n",
    )
    (OUT / "odbc_query_runner.dart").write_text(query, encoding="utf-8")
    print("Wrote odbc_query_runner.dart", query.count("\n") + 1, "lines")

    stream = build_runner(
        "OdbcStreamRunner",
        "Streaming query and async-poll operations.",
        """  OdbcStreamRunner({
    required this.ffi,
    required this.state,
    required this.connection,
    required this.parser,
    required this.query,
  });

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;
  final OdbcConnectionRunner connection;
  final OdbcResultParser parser;
  final OdbcQueryRunner query;""",
        [
            "streamQueryMulti",
            "streamQuery",
            "streamQueryNamed",
            "_streamNativeQueryWithFallback",
            "_isStreamingTimeoutException",
            "_isStreamingProtocolException",
            "_isStreamingInterruptionException",
            "_streamingFailureFromException",
            "cancelStream",
            "executeAsyncStart",
            "asyncPoll",
            "asyncGetResult",
            "asyncCancel",
            "asyncFree",
            "streamStartAsync",
            "streamPollAsync",
        ],
        STREAM_IMPORTS,
        src,
        extra_repl=[
            (r"\bexecuteQueryMultiFull\(", "query.executeQueryMultiFull("),
            (r"\bexecuteQueryNamed\(", "query.executeQueryNamed("),
        ],
    )
    stream = stream.replace(
        "_streamNativeQueryWithFallback",
        "streamNativeQueryWithFallback",
    )
    stream = stream.replace(
        "_streamingFailureFromException",
        "streamingFailureFromException",
    )
    (OUT / "odbc_stream_runner.dart").write_text(stream, encoding="utf-8")
    print("Wrote odbc_stream_runner.dart", stream.count("\n") + 1, "lines")

    admin = build_runner(
        "OdbcAdminRunner",
        "Metrics, audit, capabilities, and metadata-cache operations.",
        """  OdbcAdminRunner({
    required this.ffi,
    required this.state,
  });

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;""",
        [
            "getMetrics",
            "getWorkerPoolStats",
            "getVersion",
            "validateConnectionString",
            "getDriverCapabilities",
            "getConnectionDbmsInfo",
            "setLogLevel",
            "setAuditEnabled",
            "getAuditStatus",
            "getAuditEvents",
            "clearAuditEvents",
            "metadataCacheEnable",
            "metadataCacheStats",
            "clearMetadataCache",
            "detectDriver",
            "_decodeJsonMap",
            "_decodeJsonMapList",
        ],
        ADMIN_IMPORTS,
        src,
    )
    (OUT / "odbc_admin_runner.dart").write_text(admin, encoding="utf-8")
    print("Wrote odbc_admin_runner.dart", admin.count("\n") + 1, "lines")


if __name__ == "__main__":
    main()

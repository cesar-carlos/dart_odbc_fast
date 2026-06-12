#!/usr/bin/env python3
"""Mechanical split of odbc_repository_impl.dart into runners + thin facade."""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
IMPL = ROOT / "lib/infrastructure/repositories/odbc_repository_impl.dart"
OUT_IMPL = IMPL
RUNNERS = ROOT / "lib/infrastructure/repositories/runners"

STATE_REPLACEMENTS = [
    (r"\b_connectionIds\b", "state.connectionIds"),
    (r"\b_connectionOptions\b", "state.connectionOptions"),
    (r"\b_connectionStrings\b", "state.connectionStrings"),
    (r"\b_namedParamOrderByStmtId\b", "state.namedParamOrderByStmtId"),
    (r"\b_statementConnectionByStmtId\b", "state.statementConnectionByStmtId"),
    (r"\b_poolCheckouts\b", "state.poolCheckouts"),
    (r"\b_connectionPoolId\b", "state.connectionPoolId"),
    (r"\b_clearStatementMetadataForConnection\b", "state.clearStatementMetadataForConnection"),
    (r"\b_clearAllStatementMetadata\b", "state.clearAllStatementMetadata"),
    (r"\b_optionsFor\b", "state.optionsFor"),
    (r"\b_validateStatementOwnership\b", "state.validateStatementOwnership"),
]

FFI_REPLACEMENTS = [
    (r"\b_isAsync\b", "ffi.isAsync"),
    (r"\b_async\b", "ffi.async"),
    (r"\b_sync\b", "ffi.sync"),
    (r"\b_backend\b", "ffi._backend"),
    (r"\b_runBoolFfi\b", "ffi.runBoolFfi"),
    (r"\b_runBoolFfiWithCleanup\b", "ffi.runBoolFfiWithCleanup"),
    (r"\b_runIntFfi\b", "ffi.runIntFfi"),
    (r"\b_convertNativeErrorToFailure\b", "ffi.convertNativeErrorToFailure"),
    (r"\b_getStructuredNativeError\b", "ffi.getStructuredNativeError"),
]

PARSER_REPLACEMENTS = [
    (r"\b_parseBufferToQueryResult\b", "parser.parseBufferToQueryResult"),
    (r"\b_toQueryResult\b", "parser.toQueryResult"),
    (r"\b_toQueryResultMulti\b", "parser.toQueryResultMulti"),
    (r"\b_toQueryResultMultiItem\b", "parser.toQueryResultMultiItem"),
]

CONST_REPLACEMENTS = [
    (r"\b_queryErrorFactory\b", "odbcQueryErrorFactory"),
    (r"\b_connectionErrorFactory\b", "odbcConnectionErrorFactory"),
    (r"\b_queryTimedOutMessage\b", "odbcQueryTimedOutMessage"),
    (r"\b_streamProtocolErrorPrefix\b", "odbcStreamProtocolErrorPrefix"),
    (r"\b_streamInterruptedPrefix\b", "odbcStreamInterruptedPrefix"),
    (r"\b_isUnsupportedCancellation\b", "isUnsupportedCancellation"),
]

EVENT_REPLACEMENTS = [
    (r"\b_emit\b", "emit"),
    (r"\b_maybeEmitSlowQuery\b", "maybeEmitSlowQuery"),
]


def transform(body: str, extra: list[tuple[str, str]] | None = None) -> str:
    for old, new in (
        STATE_REPLACEMENTS
        + FFI_REPLACEMENTS
        + PARSER_REPLACEMENTS
        + CONST_REPLACEMENTS
        + EVENT_REPLACEMENTS
        + (extra or [])
    ):
        body = re.sub(old, new, body)
    return body


def extract_method(text: str, name: str) -> str | None:
    # Match @override optional, Future/Stream return, method name
    pattern = rf"(  (?:@override\n)?  (?:Future<[^>]+>|Stream<[^>]+>|bool|void|DartSideMetrics|String\?)[^\n]*\n)?  (?:Future<[^>]+>|Stream<[^>]+>|bool|void|DartSideMetrics|String\?)?\s*{re.escape(name)}\([^)]*\)(?: async\*)?(?: async)?(?: => [^;]+;|\s*\{{)"
    m = re.search(pattern, text)
    if not m:
        return None
    start = m.start()
    if "=>" in text[m.start() : m.end()]:
        end = text.find(";", m.end()) + 1
        return text[start:end]
    # brace matching
    i = text.find("{", m.end() - 1)
    depth = 0
    j = i
    while j < len(text):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[start : j + 1]
        j += 1
    return None


def strip_override_and_dedent(method: str, indent: str = "  ") -> str:
    lines = method.splitlines()
    out = []
    for line in lines:
        if line.strip() == "@override":
            continue
        if line.startswith("  "):
            out.append(indent + line[2:])
        else:
            out.append(line)
    return "\n".join(out)


def main() -> int:
    text = IMPL.read_text(encoding="utf-8")
    print("Read", len(text.splitlines()), "lines from impl")
    # sanity: key methods exist
    for name in ["connect", "executeQuery", "poolCreate", "beginTransaction"]:
        if extract_method(text, name) is None:
            print("WARN: could not extract", name)
    print("Script is a helper scaffold — runners are authored manually.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

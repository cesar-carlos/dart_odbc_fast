"""One-shot splitter for large Dart infrastructure modules (structural refactor).

Regenerates part files from the pre-split monolith at HEAD. Run from repo root:

    python tool/split_structural_parts.py

After structural edits, prefer editing the part files directly; re-run only when
rebasing a split onto an updated monolith.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _write(path: Path, content: str) -> None:
    if not content.endswith("\n"):
        content += "\n"
    path.write_text(content, encoding="utf-8", newline="\n")
    print(f"  wrote {path.relative_to(ROOT)} ({len(content.splitlines())} lines)")


def _slice(lines: list[str], start: int, end: int) -> str:
    """1-based inclusive line range."""
    return "".join(lines[start - 1 : end])


def split_param_value() -> None:
    src = ROOT / "lib/infrastructure/native/protocol/param_value.dart"
    lines = src.read_text(encoding="utf-8").splitlines(keepends=True)

    main = "library;\n\n"
    main += _slice(lines, 1, 100)
    main += "part 'param_value_wire.dart';\n"
    main += "part 'param_value_conversion.dart';\n"
    main += "part 'param_value_validators.dart';\n"
    _write(src, main)

    _write(
        src.parent / "param_value_wire.dart",
        "part of 'param_value.dart';\n\n" + _slice(lines, 102, 259),
    )
    _write(
        src.parent / "param_value_conversion.dart",
        "part of 'param_value.dart';\n\n"
        + _slice(lines, 261, 553)
        + "\n"
        + _slice(lines, 924, len(lines)),
    )
    _write(
        src.parent / "param_value_validators.dart",
        "part of 'param_value.dart';\n\n" + _slice(lines, 555, 922),
    )


def split_odbc_native_query() -> None:
    src = ROOT / "lib/infrastructure/native/bindings/odbc_native_query.dart"
    if not src.exists():
        print("  skip odbc_native_query (already split)")
        return
    lines = src.read_text(encoding="utf-8").splitlines(keepends=True)

    sections = [
        ("odbc_native_query_async.dart", "_OdbcNativeQueryAsync", 4, 131),
        ("odbc_native_query_sync.dart", "_OdbcNativeQuerySync", 133, 426),
        ("odbc_native_query_catalog.dart", "_OdbcNativeQueryCatalog", 428, 562),
        ("odbc_native_query_prepare.dart", "_OdbcNativeQueryPrepare", 564, 688),
        ("odbc_native_query_bulk.dart", "_OdbcNativeQueryBulk", 690, 791),
    ]

    native = ROOT / "lib/infrastructure/native/bindings/odbc_native.dart"
    native_text = native.read_text(encoding="utf-8")
    native_text = native_text.replace(
        "part 'odbc_native_query.dart';\n",
        "".join(f"part '{name}';\n" for name, _, _, _ in sections),
    )
    native_text = native_text.replace(
        "        _OdbcNativeQuery,\n",
        "".join(f"        {mixin},\n" for _, mixin, _, _ in sections),
    )
    _write(native, native_text)

    for fname, mixin, start, end in sections:
        body = _slice(lines, start, end)
        content = (
            "part of 'odbc_native.dart';\n\n"
            f"mixin {mixin} on _OdbcNativeState, _OdbcNativeHelpers {{\n"
            f"{body}"
            "}\n"
        )
        _write(src.parent / fname, content)

    src.unlink()


def main() -> None:
    print("split_param_value")
    split_param_value()
    print("split_odbc_native_query")
    split_odbc_native_query()
    print("done (bulk_insert_builder: edit parts manually; see git history)")


if __name__ == "__main__":
    main()

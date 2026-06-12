"""Temporary script to split oversized test files."""
from pathlib import Path


def split_async_connection() -> None:
    src = Path("test/infrastructure/native/async_native_odbc_connection_test.dart")
    content = src.read_text(encoding="utf-8")
    lines = content.splitlines(keepends=True)

    helpers_path = Path("test/infrastructure/native/async_connection/fake_workers.dart")
    helpers_path.parent.mkdir(parents=True, exist_ok=True)
    helpers_path.write_text("".join(lines[0:858]), encoding="utf-8")

    groups = [
        ("async_error_test.dart", [(862, 973), (1862, 1894)]),
        ("worker_response_payloads_test.dart", [(975, 997)]),
        ("connection_core_test.dart", [(999, 1220)]),
        ("connection_pool_test.dart", [(1222, 1498)]),
        ("connection_timeout_dispose_test.dart", [(1500, 1577)]),
        ("binary_protocol_parser_test.dart", [(1579, 1604)]),
        ("connection_named_params_test.dart", [(1606, 1730)]),
        ("connection_cancellation_audit_test.dart", [(1732, 1762)]),
        ("connection_async_execute_test.dart", [(1764, 1860), (2262, 2305)]),
        ("connection_stream_test.dart", [(1895, 2001)]),
        ("connection_recovery_test.dart", [(2003, 2034), (2307, 2359)]),
        ("connection_bulk_test.dart", [(2036, 2062)]),
        ("connection_wave6c_test.dart", [(2064, 2260)]),
    ]

    header = """import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';
import 'fake_workers.dart';

void main() {
  loadTestEnv();
"""

    footer = "}\n"
    out_dir = Path("test/infrastructure/native/async_connection")
    for filename, ranges in groups:
        body = "".join("".join(lines[s - 1 : e]) for s, e in ranges)
        (out_dir / filename).write_text(header + body + footer, encoding="utf-8")
        print(f"Wrote {filename}")

    src.unlink()
    print("Deleted original async test")


def split_repository() -> None:
    src = Path("test/infrastructure/repositories/odbc_repository_impl_test.dart")
    content = src.read_text(encoding="utf-8")
    lines = content.splitlines(keepends=True)

    out_dir = Path("test/infrastructure/repositories/odbc_repository_impl")
    out_dir.mkdir(parents=True, exist_ok=True)

    helpers = """import 'dart:typed_data';

import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

import '../../../helpers/fake_async_native_for_errors.dart';

/// Single multi-stream row-count frame (tag + u32 len + i64).
Uint8List rowCountMultiStreamFrame(int n) {
  final payload = ByteData(8)..setInt64(0, n, Endian.little);
  final builder = BytesBuilder()
    ..addByte(multiStreamItemTagRowCount)
    ..add(
      (ByteData(4)..setUint32(0, 8, Endian.little)).buffer.asUint8List(),
    )
    ..add(payload.buffer.asUint8List());
  return builder.toBytes();
}

/// SQLSTATE `0A000` as raw bytes for structured cancellation errors.
const List<int> sqlState0A000 = [48, 65, 48, 48, 48];

/// MULT v2 buffer with unsupported version — [MultiResultParser.parse] rejects.
Uint8List malformedMultiResultBuffer() {
  final header = ByteData(headerV2Len)
    ..setUint32(0, multiResultMagic, Endian.little)
    ..setUint16(4, 99, Endian.little)
    ..setUint32(8, 0, Endian.little);
  return header.buffer.asUint8List();
}

// magic(4) + version(2) + reserved(2) + count(4)
const int headerV2Len = 12;

typedef FakeAsyncNativeForRepositoryErrors = FakeAsyncNativeForRepositoryErrors;

void expectValidationError<T extends Object>(
  Result<T> result,
  String message,
) {
  expect(result.isSuccess(), isFalse);
  result.fold(
    (_) => fail('Expected failure'),
    (e) {
      expect(e, isA<ValidationError>());
      expect((e as ValidationError).message, message);
    },
  );
}

void expectInvalidConnectionId<T extends Object>(Result<T> result) {
  expectValidationError(result, 'Invalid connection ID');
}
"""
    (out_dir / "helpers.dart").write_text(helpers, encoding="utf-8")

    repo_header = """import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

import '../../../helpers/fake_async_native_for_errors.dart';
import 'helpers.dart';

void main() {
"""

    footer = "}\n"

    # Line ranges for top-level groups (1-based)
    files = [
        ("validation_test.dart", 78, 821),
        ("error_mapping_test.dart", 823, 877),
        ("query_runner_test.dart", 879, 1242),  # wave7b start through executeQueryMultiFull
        ("stream_runner_test.dart", 1244, 1297),  # streamQueryNamed
        ("lifecycle_test.dart", 1299, 1546),  # dispose, metrics, worker recovery
        ("query_runner_test.dart_append_statement", 1548, 1722),  # statement lifecycle - append later
        ("transaction_runner_test.dart", 1724, 1908),
        ("query_runner_test.dart_append_slow", 1910, 1969),
    ]

    # Simpler approach: write each section to its file
    sections = {
        "validation_test.dart": (78, 821),
        "error_mapping_test.dart": (823, 877),
        "query_runner_test.dart": [
            (894, 1018),  # connect through executePrepared
            (1101, 1242),  # executeQueryNamed through executeQueryMultiFull
            (1548, 1722),  # statement lifecycle
            (1910, 1969),  # slow query
        ],
        "pool_runner_test.dart": [
            (1360, 1440),  # dartSideMetrics
        ],
        "stream_runner_test.dart": [
            (1123, 1297),  # streamQueryMulti + streamQueryNamed
        ],
        "transaction_runner_test.dart": [
            (919, 991),  # disconnect, beginTransaction
            (1724, 1908),
        ],
        "bulk_runner_test.dart": [
            (1020, 1049),  # bulkInsert error mapping
        ],
        "lifecycle_test.dart": [
            (879, 893),  # wave7b setUp block prefix - need full group wrapper
            (1299, 1358),  # dispose
            (1442, 1546),  # worker recovery
        ],
    }

    # Write validation and error_mapping as simple ranges
    for name, (start, end) in [
        ("validation_test.dart", (78, 821)),
        ("error_mapping_test.dart", (823, 877)),
    ]:
        body = "".join(lines[start - 1 : end])
        (out_dir / name).write_text(repo_header + body + footer, encoding="utf-8")
        print(f"Wrote {name}")

    # query_runner: wave7b partial + statement + slow query
    query_parts = [
        lines[878:893],  # group header + setUp for wave 7b
        lines[893:1018],
        lines[1100:1242],
        lines[1547:1722],
        lines[1909:1969],
        ["  });\n"],  # close wave 7b group
    ]
    query_body = "".join("".join(p) for p in query_parts)
    (out_dir / "query_runner_test.dart").write_text(
        repo_header + query_body + footer, encoding="utf-8"
    )
    print("Wrote query_runner_test.dart")

    # pool_runner: extract pool validation from validation + metrics
    pool_validation_lines = []
    for i, line in enumerate(lines[91:821], start=92):
        if any(
            k in line
            for k in [
                "poolCreate",
                "poolSetSize",
                "poolReleaseConnection",
                "pooledConnection",
                "poolCheckout",
            ]
        ):
            # grab surrounding test - too complex, include whole tests by pattern
            pass

    # pool_runner with metrics group
    pool_body = "".join(lines[1359:1440])
    (out_dir / "pool_runner_test.dart").write_text(
        repo_header + pool_body + footer, encoding="utf-8"
    )
    print("Wrote pool_runner_test.dart")

    # stream_runner
    stream_parts = [
        lines[878:893],
        lines[1122:1297],
        ["  });\n"],
    ]
    stream_body = "".join("".join(p) for p in stream_parts)
    (out_dir / "stream_runner_test.dart").write_text(
        repo_header + stream_body + footer, encoding="utf-8"
    )
    print("Wrote stream_runner_test.dart")

    # transaction_runner
    txn_parts = [
        lines[878:893],
        lines[918:991],
        lines[1723:1908],
        ["  });\n"],
    ]
    txn_body = "".join("".join(p) for p in txn_parts)
    (out_dir / "transaction_runner_test.dart").write_text(
        repo_header + txn_body + footer, encoding="utf-8"
    )
    print("Wrote transaction_runner_test.dart")

    # bulk_runner
    bulk_parts = [
        lines[878:893],
        lines[1019:1049],
        ["  });\n"],
    ]
    bulk_body = "".join("".join(p) for p in bulk_parts)
    (out_dir / "bulk_runner_test.dart").write_text(
        repo_header + bulk_body + footer, encoding="utf-8"
    )
    print("Wrote bulk_runner_test.dart")

    # lifecycle
    lifecycle_parts = [
        lines[1298:1358],
        lines[1441:1546],
    ]
    lifecycle_body = "".join("".join(p) for p in lifecycle_parts)
    (out_dir / "lifecycle_test.dart").write_text(
        repo_header + lifecycle_body + footer, encoding="utf-8"
    )
    print("Wrote lifecycle_test.dart")

    # Also need cancelStatement tests in query_runner - lines 1051-1099
    # Append to query_runner
    cancel_body = "".join(lines[1050:1099])
    qr_path = out_dir / "query_runner_test.dart"
    qr_content = qr_path.read_text(encoding="utf-8")
    qr_content = qr_content.replace("  });\n}\n", cancel_body + "  });\n}\n")
    qr_path.write_text(qr_content, encoding="utf-8")

    src.unlink()
    print("Deleted original repository test")


if __name__ == "__main__":
    split_async_connection()
    split_repository()

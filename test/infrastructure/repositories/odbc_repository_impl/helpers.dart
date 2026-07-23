import 'dart:typed_data';

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

/// Streaming multi-result result-set frame with a simple varchar payload.
Uint8List resultSetMultiStreamFrame(
  List<String> columns,
  List<List<String>> rows, {
  int tag = multiStreamItemTagResultSet,
}) {
  final cols = <int>[];
  for (final c in columns) {
    final nameBytes = c.codeUnits;
    cols.addAll([
      0x01,
      0x00,
      nameBytes.length & 0xFF,
      (nameBytes.length >> 8) & 0xFF,
      ...nameBytes,
    ]);
  }
  final rowsBytes = <int>[];
  for (final row in rows) {
    for (final cell in row) {
      final cellBytes = cell.codeUnits;
      rowsBytes
        ..add(0)
        ..addAll([
          cellBytes.length & 0xFF,
          (cellBytes.length >> 8) & 0xFF,
          (cellBytes.length >> 16) & 0xFF,
          (cellBytes.length >> 24) & 0xFF,
        ])
        ..addAll(cellBytes);
    }
  }
  final payloadAfterHeader = <int>[...cols, ...rowsBytes];
  final colCount = columns.length;
  final rowCount = rows.length;
  final payloadSize = payloadAfterHeader.length;
  final header = <int>[
    0x43,
    0x42,
    0x44,
    0x4F,
    0x01,
    0x00,
    colCount & 0xFF,
    (colCount >> 8) & 0xFF,
    rowCount & 0xFF,
    (rowCount >> 8) & 0xFF,
    (rowCount >> 16) & 0xFF,
    (rowCount >> 24) & 0xFF,
    payloadSize & 0xFF,
    (payloadSize >> 8) & 0xFF,
    (payloadSize >> 16) & 0xFF,
    (payloadSize >> 24) & 0xFF,
  ];
  final inner = Uint8List.fromList([...header, ...payloadAfterHeader]);
  final out = BytesBuilder()
    ..addByte(tag)
    ..add(
      (ByteData(4)..setUint32(0, inner.length, Endian.little))
          .buffer
          .asUint8List(),
    )
    ..add(inner);
  return out.toBytes();
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

typedef FakeRepoNative = FakeAsyncNativeForRepositoryErrors;

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

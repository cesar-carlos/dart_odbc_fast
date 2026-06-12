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

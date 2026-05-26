/// Unit tests for [OdbcBulkRunner].
library;

import 'dart:typed_data';

import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_bulk_runner.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

class _FakeNativeForBulk extends NativeOdbcConnection {
  int bulkInsertArrayResult = 100;
  int bulkInsertParallelResult = 200;
  int poolGetConnectionResult = 7;
  bool poolReleaseConnectionResult = true;

  String? lastTable;
  List<String>? lastColumns;
  int? lastRowCount;

  @override
  int bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) {
    lastTable = table;
    lastColumns = columns;
    lastRowCount = rowCount;
    return bulkInsertArrayResult;
  }

  @override
  int bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int parallelism,
  ) {
    lastTable = table;
    lastColumns = columns;
    return bulkInsertParallelResult;
  }

  @override
  int poolGetConnection(int poolId) => poolGetConnectionResult;

  @override
  bool poolReleaseConnection(int connectionId) => poolReleaseConnectionResult;
}

Future<Failure<int, OdbcError>> _stubConvertError({
  required String fallbackMessage,
  int? nativeConnectionId,
}) async =>
    Failure<int, OdbcError>(QueryError(message: fallbackMessage));

void main() {
  group('OdbcBulkRunner.bulkInsert', () {
    late _FakeNativeForBulk native;
    late OdbcBulkRunner runner;

    setUp(() {
      native = _FakeNativeForBulk();
      runner = OdbcBulkRunner(
        backend: SyncBackend(native),
        nativeIdLookup: (id) => id == 'good' ? 99 : null,
        convertIntError: _stubConvertError,
      );
    });

    tearDown(() => native.dispose());

    test('returns ValidationError when connectionId is unknown', () async {
      final r = await runner.bulkInsert('unknown', 't', ['c'], [1, 2, 3], 1);
      expect(r.isError(), isTrue);
      expect(r.exceptionOrNull(), isA<ValidationError>());
    });

    test('forwards table, columns, rowCount and returns affected rows',
        () async {
      native.bulkInsertArrayResult = 42;
      final r = await runner.bulkInsert('good', 'logs', ['msg'], [1, 2], 5);
      expect(r.isSuccess(), isTrue);
      expect(r.getOrNull(), equals(42));
      expect(native.lastTable, equals('logs'));
      expect(native.lastColumns, equals(['msg']));
      expect(native.lastRowCount, equals(5));
    });

    test('converts negative result into QueryError via injected mapper',
        () async {
      native.bulkInsertArrayResult = -1;
      final r = await runner.bulkInsert('good', 'logs', ['msg'], [1, 2], 5);
      expect(r.isError(), isTrue);
      final err = r.exceptionOrNull()! as QueryError;
      expect(err.message, contains('Failed to bulk insert'));
    });
  });

  group('OdbcBulkRunner.bulkInsertParallel', () {
    late _FakeNativeForBulk native;
    late OdbcBulkRunner runner;

    setUp(() {
      native = _FakeNativeForBulk();
      runner = OdbcBulkRunner(
        backend: SyncBackend(native),
        nativeIdLookup: (id) => 1,
        convertIntError: _stubConvertError,
      );
    });

    tearDown(() => native.dispose());

    test('rejects invalid pool id', () async {
      final r = await runner.bulkInsertParallel(0, 't', ['c'], [1], 1);
      expect(r.isError(), isTrue);
      expect(r.exceptionOrNull(), isA<ValidationError>());
    });

    test('rejects empty table name', () async {
      final r = await runner.bulkInsertParallel(1, '', ['c'], [1], 1);
      expect(r.exceptionOrNull(), isA<ValidationError>());
    });

    test('rejects empty columns', () async {
      final r = await runner.bulkInsertParallel(1, 't', [], [1], 1);
      expect(r.exceptionOrNull(), isA<ValidationError>());
    });

    test('rejects empty data buffer', () async {
      final r = await runner.bulkInsertParallel(1, 't', ['c'], [], 1);
      expect(r.exceptionOrNull(), isA<ValidationError>());
    });

    test('rejects rowCount <= 0', () async {
      final r = await runner.bulkInsertParallel(1, 't', ['c'], [1], 0);
      expect(r.exceptionOrNull(), isA<ValidationError>());
    });

    test('falls back to single connection when parallelism <= 1', () async {
      native.bulkInsertArrayResult = 9;
      final r = await runner.bulkInsertParallel(
        1,
        't',
        ['c'],
        [1, 2],
        3,
      );
      expect(r.getOrNull(), equals(9));
    });

    test('uses parallel path when parallelism > 1', () async {
      native.bulkInsertParallelResult = 77;
      final r = await runner.bulkInsertParallel(
        1,
        't',
        ['c'],
        [1, 2],
        3,
        parallelism: 4,
      );
      expect(r.getOrNull(), equals(77));
    });
  });
}

import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:test/test.dart';

class _FakeAsyncNativeForBulkBuffer extends AsyncNativeOdbcConnection {
  _FakeAsyncNativeForBulkBuffer() : super(requestTimeout: Duration.zero);

  Uint8List? lastBulkInsertArrayBuffer;
  Uint8List? lastBulkInsertParallelBuffer;
  int poolReleaseCalls = 0;

  @override
  Future<bool> initialize() async => true;

  @override
  Future<int> connect(String connectionString, {int timeoutMs = 0}) async =>
      123;

  @override
  Future<bool> disconnect(int connectionId) async => true;

  @override
  Future<int> bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) async {
    lastBulkInsertArrayBuffer = dataBuffer;
    return rowCount;
  }

  @override
  Future<int> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int parallelism,
  ) async {
    lastBulkInsertParallelBuffer = dataBuffer;
    return parallelism;
  }

  @override
  Future<int> poolGetConnection(int poolId) async => 456;

  @override
  Future<bool> poolReleaseConnection(int connectionId) async {
    poolReleaseCalls++;
    return true;
  }

  @override
  void dispose() {}
}

void main() {
  group('OdbcRepositoryImpl bulk buffer reuse', () {
    late _FakeAsyncNativeForBulkBuffer asyncNative;
    late OdbcRepositoryImpl repository;
    late String connectionId;

    setUp(() async {
      asyncNative = _FakeAsyncNativeForBulkBuffer();
      repository = OdbcRepositoryImpl(asyncNative);
      await repository.initialize();
      final connResult = await repository.connect('DSN=Fake');
      final connection = connResult.getOrNull();
      expect(connection, isNotNull);
      connectionId = connection!.id;
    });

    test('bulkInsert reuses Uint8List input without copy', () async {
      final payload = Uint8List.fromList([1, 2, 3, 4]);

      final result = await repository.bulkInsert(
        connectionId,
        't',
        const ['c'],
        payload,
        2,
      );

      expect(result.isSuccess(), isTrue);
      expect(asyncNative.lastBulkInsertArrayBuffer, same(payload));
    });

    test('bulkInsert converts generic List<int> to Uint8List', () async {
      final payload = <int>[10, 20, 30];

      final result = await repository.bulkInsert(
        connectionId,
        't',
        const ['c'],
        payload,
        1,
      );

      expect(result.isSuccess(), isTrue);
      expect(asyncNative.lastBulkInsertArrayBuffer, isA<Uint8List>());
      expect(asyncNative.lastBulkInsertArrayBuffer, orderedEquals(payload));
    });

    test('bulkInsertParallel reuses Uint8List on parallel path', () async {
      final payload = Uint8List.fromList([7, 8, 9]);

      final result = await repository.bulkInsertParallel(
        10,
        't',
        const ['c'],
        payload,
        1,
        parallelism: 2,
      );

      expect(result.isSuccess(), isTrue);
      expect(asyncNative.lastBulkInsertParallelBuffer, same(payload));
    });

    test('bulkInsertParallel fallback reuses Uint8List and releases pool conn',
        () async {
      final payload = Uint8List.fromList([4, 5, 6]);

      final result = await repository.bulkInsertParallel(
        10,
        't',
        const ['c'],
        payload,
        1,
        parallelism: 1,
      );

      expect(result.isSuccess(), isTrue);
      expect(asyncNative.lastBulkInsertArrayBuffer, same(payload));
      expect(asyncNative.poolReleaseCalls, equals(1));
    });
  });
}

/// Unit tests for [ConnectionPool] wrapper.
library;

import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/wrappers/connection_pool.dart';
import 'package:test/test.dart';

import '../../../helpers/fake_odbc_backend.dart';

void main() {
  group('ConnectionPool', () {
    late FakeOdbcConnectionBackend backend;
    late ConnectionPool pool;

    setUp(() {
      backend = FakeOdbcConnectionBackend();
      pool = ConnectionPool(backend, 10);
    });

    test('poolId returns constructor value', () {
      expect(pool.poolId, 10);
    });

    test('getConnection returns backend result', () {
      backend.poolGetConnectionResult = 1;
      expect(pool.getConnection(), 1);

      backend.poolGetConnectionResult = 0;
      expect(pool.getConnection(), 0);
    });

    test('releaseConnection returns backend result', () {
      backend.poolReleaseConnectionResult = true;
      expect(pool.releaseConnection(1), true);

      backend.poolReleaseConnectionResult = false;
      expect(pool.releaseConnection(1), false);
    });

    test('healthCheck returns backend result', () {
      backend.poolHealthCheckResult = true;
      expect(pool.healthCheck(), true);

      backend.poolHealthCheckResult = false;
      expect(pool.healthCheck(), false);
    });

    test('getState returns backend result', () {
      backend.poolGetStateResult = (size: 5, idle: 3);
      final state = pool.getState();
      expect(state, isNotNull);
      expect(state!.size, 5);
      expect(state.idle, 3);

      backend.poolGetStateResult = null;
      expect(pool.getState(), isNull);
    });

    test('setSize returns backend result', () {
      backend.poolSetSizeResult = true;
      expect(pool.setSize(12), isTrue);

      backend.poolSetSizeResult = false;
      expect(pool.setSize(12), isFalse);
    });

    test('close returns backend result', () {
      backend.poolCloseResult = true;
      expect(pool.close(), true);

      backend.poolCloseResult = false;
      expect(pool.close(), false);
    });

    test('bulkInsertParallel returns backend result', () {
      backend.bulkInsertParallelResult = 100;
      final buffer = Uint8List(16);
      expect(
        pool.bulkInsertParallel('t', ['c1'], buffer),
        100,
      );

      backend.bulkInsertParallelResult = -1;
      expect(
        pool.bulkInsertParallel('t', ['c1'], buffer),
        -1,
      );
    });
  });
}

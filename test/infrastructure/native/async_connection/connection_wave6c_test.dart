import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';
import 'fake_workers.dart';

void main() {
  loadTestEnv();
  group('AsyncNativeOdbcConnection Wave 6C', () {
    test('should map transactionFailed and prepareFailed to QueryError', () {
      const transaction = AsyncError(
        code: AsyncErrorCode.transactionFailed,
        message: 'commit failed',
        sqlState: '40001',
        nativeCode: 9,
      );
      const prepare = AsyncError(
        code: AsyncErrorCode.prepareFailed,
        message: 'prepare failed',
        sqlState: '42000',
        nativeCode: 10,
      );

      final transactionError = transaction.toOdbcError();
      final prepareError = prepare.toOdbcError();

      expect(transactionError, isA<QueryError>());
      expect(transactionError.message, equals('commit failed'));
      expect(transactionError.sqlState, equals('40001'));
      expect(transactionError.nativeCode, equals(9));

      expect(prepareError, isA<QueryError>());
      expect(prepareError.message, equals('prepare failed'));
      expect(prepareError.sqlState, equals('42000'));
      expect(prepareError.nativeCode, equals(10));
    });

    test('should map worker connect failure to connectionFailed AsyncError',
        () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerFastLifecycle,
      );
      await async.initialize();

      try {
        await async.connect('DSN=fail');
        fail('Expected AsyncError');
      } on AsyncError catch (e) {
        expect(e.code, equals(AsyncErrorCode.connectionFailed));
        expect(e.message, equals('login denied'));
        expect(e.toOdbcError(), isA<ConnectionError>());
      } finally {
        async.dispose();
      }
    });

    test('should not spawn worker isolate before initialize', () {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerFastLifecycle,
      );

      expect(async.workerIsolateForTesting, isNull);
      expect(async.isInitialized, isFalse);
    });

    test('should expose zeroed pool stats before initialize', () {
      final async = AsyncNativeOdbcConnection(workerCount: 2);
      final stats = async.getWorkerPoolStats();

      expect(stats.workerCount, equals(2));
      expect(stats.workers, isEmpty);
      expect(stats.activeRequests, equals(0));
      expect(stats.pendingRequests, equals(0));
      expect(stats.totalRouted, equals(0));
      expect(stats.completedRequests, equals(0));
      expect(stats.failedRequests, equals(0));
      expect(stats.timeouts, equals(0));
      expect(stats.latencyP95Micros, equals(0));
    });

    test('should throw StateError when routing before initialize', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerFastLifecycle,
      );

      expect(
        async.getVersion,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not initialized'),
          ),
        ),
      );
    });

    test('should increment completedRequests after successful round trip',
        () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerFastLifecycle,
      );
      await async.initialize();

      final version = await async.getVersion();
      final stats = async.getWorkerPoolStats();

      expect(version, equals({'api': 'test-api', 'abi': 'test-abi'}));
      expect(stats.completedRequests, greaterThanOrEqualTo(2));
      expect(stats.failedRequests, equals(0));
      expect(stats.timeouts, equals(0));
      expect(stats.latencyMaxMicros, greaterThanOrEqualTo(0));
      async.dispose();
    });

    test('should aggregate per-worker stats after parallel connects', () async {
      final async = AsyncNativeOdbcConnection(
        workerCount: 2,
        isolateEntry: fakeWorkerFastLifecycle,
      );
      await async.initialize();

      final ids = await Future.wait([
        async.connect('DSN=a'),
        async.connect('DSN=b'),
      ]);
      final stats = async.getWorkerPoolStats();

      expect(ids, hasLength(2));
      expect(stats.workers, hasLength(2));
      expect(
        stats.workers.map((worker) => worker.totalRouted),
        everyElement(greaterThanOrEqualTo(2)),
      );
      expect(stats.totalRouted, greaterThanOrEqualTo(4));
      expect(stats.completedRequests, greaterThanOrEqualTo(4));

      for (final connectionId in ids) {
        await async.disconnect(connectionId);
      }
      async.dispose();
    });

    test('should return stable aggregate p95 between stats snapshots',
        () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerFastLifecycle,
      );
      await async.initialize();
      await async.getVersion();

      final first = async.getWorkerPoolStats();
      final second = async.getWorkerPoolStats();

      expect(first.latencyP95Micros, equals(second.latencyP95Micros));
      expect(first.queueWaitP95Micros, equals(second.queueWaitP95Micros));
      expect(first.executionP95Micros, equals(second.executionP95Micros));
      async.dispose();
    });

    test('dispose without initialize should be safe', () {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerFastLifecycle,
      );

      expect(async.dispose, returnsNormally);
      expect(async.isInitialized, isFalse);
    });

    test('should complete pending requests with workerTerminated on dispose',
        () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 60),
        isolateEntry: fakeWorkerNoResponse,
      );
      await async.initialize();

      final pending = async.connect('DSN=blocked');
      async.dispose();

      await expectLater(
        pending,
        throwsA(
          isA<AsyncError>()
              .having((e) => e.code, 'code', AsyncErrorCode.workerTerminated)
              .having(
                (e) => e.message,
                'message',
                contains('Connection disposed'),
              ),
        ),
      );
    });

    test('failWorkerForTesting should ignore unknown worker index', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerFastLifecycle,
      );
      await async.initialize();

      expect(() => async.failWorkerForTesting(99), returnsNormally);
      expect(async.isInitialized, isTrue);
      async.dispose();
    });
  });
}

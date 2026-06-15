import 'dart:typed_data';

import 'package:odbc_fast/odbc_fast.dart';
import 'package:odbc_fast/odbc_fast_native.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';
import 'fake_workers.dart';

void main() {
  loadTestEnv();
  group('AsyncNativeOdbcConnection worker pool', () {
    test('distributes independent connection requests across workers',
        () async {
      final async = AsyncNativeOdbcConnection(
        workerCount: 2,
        isolateEntry: fakeWorkerPoolRoutingSupport,
      );
      await async.initialize();

      final stopwatch = Stopwatch()..start();
      await Future.wait([
        async.connect('DSN=fast_a'),
        async.connect('DSN=fast_b'),
      ]);
      stopwatch.stop();

      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(220),
        reason: 'Two 120ms connect requests should run in parallel',
      );
      async.dispose();
    });

    test('spreads sequential connection affinities across workers', () async {
      final async = AsyncNativeOdbcConnection(
        workerCount: 3,
        isolateEntry: fakeWorkerPoolRoutingSupport,
      );
      await async.initialize();

      final connections = <int>[];
      try {
        for (var i = 0; i < 3; i++) {
          connections.add(await async.connect('DSN=fast_$i'));
        }

        final stats = async.getWorkerPoolStats();
        expect(
          stats.workers.map((worker) => worker.totalRouted),
          everyElement(greaterThanOrEqualTo(2)),
        );
      } finally {
        for (final connectionId in connections) {
          await async.disconnect(connectionId);
        }
        async.dispose();
      }
    });

    test('preserves connection affinity for subsequent operations', () async {
      final async = AsyncNativeOdbcConnection(
        workerCount: 2,
        isolateEntry: fakeWorkerPoolRoutingSupport,
      );
      await async.initialize();

      final slow = async.connect('DSN=slow');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final fastConnectionId = await async.connect('DSN=fast');
      await slow;

      final data = await async.executeQueryParams(
        fastConnectionId,
        'SELECT ?',
        [const ParamValueInt32(1)],
      );

      expect(data, equals(Uint8List.fromList([1])));
      async.dispose();
    });

    test('fails deterministically when maxPendingRequests is exceeded',
        () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 60),
        isolateEntry: fakeWorkerNoResponse,
        maxPendingRequests: 1,
      );
      await async.initialize();

      final blocked = async.connect('DSN=blocked');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      try {
        await async.connect('DSN=overflow');
        fail('Expected resourceExhausted');
      } on AsyncError catch (e) {
        expect(e.code, equals(AsyncErrorCode.resourceExhausted));
        expect(e.message, contains('queue is full'));
      } finally {
        async.dispose();
      }

      await expectLater(blocked, throwsA(isA<AsyncError>()));
    });

    test('waitForSlot releases queued requests in FIFO order', () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 5),
        isolateEntry: fakeWorkerPoolRoutingSupport,
        maxPendingRequests: 1,
        backpressureMode: AsyncBackpressureMode.waitForSlot,
      );
      await async.initialize();

      final first = async.connect('DSN=slow');
      final second = async.connect('DSN=fast');
      final ids = await Future.wait([first, second]);

      expect(ids, hasLength(2));
      expect(ids.first, isNot(equals(ids.last)));
      expect(
        async.getWorkerPoolStats().completedRequests,
        greaterThanOrEqualTo(3),
      );
      async.dispose();
    });

    test('waitForSlot reroutes queued independent requests after slot opens',
        () async {
      final async = AsyncNativeOdbcConnection(
        workerCount: 2,
        requestTimeout: const Duration(seconds: 5),
        isolateEntry: fakeWorkerPoolRoutingSupport,
        maxPendingRequests: 2,
        backpressureMode: AsyncBackpressureMode.waitForSlot,
      );
      await async.initialize();

      final first = async.connect('DSN=slow_a');
      final second = async.connect('DSN=fast_b');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final third = async.connect('DSN=fast_c');

      final ids = await Future.wait([first, second, third]);
      final routed = async
          .getWorkerPoolStats()
          .workers
          .map((worker) => worker.totalRouted)
          .toList(growable: false);

      expect(ids.toSet(), hasLength(3));
      expect(
        routed,
        equals([2, 3]),
        reason: 'The queued third connect initially picks worker 0 while both '
            'workers are busy, then should reroute to worker 1 when worker 1 '
            'frees the first slot.',
      );
      async.dispose();
    });

    test('waitForSlot times out with resourceExhausted', () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 60),
        isolateEntry: fakeWorkerNoResponse,
        maxPendingRequests: 1,
        backpressureMode: AsyncBackpressureMode.waitForSlot,
        backpressureTimeout: const Duration(milliseconds: 30),
      );
      await async.initialize();

      final blocked = async.connect('DSN=blocked');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await expectLater(
        async.connect('DSN=queued'),
        throwsA(
          isA<AsyncError>().having(
            (e) => e.code,
            'code',
            AsyncErrorCode.resourceExhausted,
          ),
        ),
      );
      async.dispose();
      await expectLater(blocked, throwsA(isA<AsyncError>()));
    });

    test('reports active, pending and routed worker pool stats', () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 60),
        isolateEntry: fakeWorkerNoResponse,
      );
      await async.initialize();

      final blocked = async.connect('DSN=blocked');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final stats = async.getWorkerPoolStats();

      expect(stats.workerCount, equals(1));
      expect(stats.activeRequests, equals(1));
      expect(stats.pendingRequests, equals(1));
      expect(stats.totalRouted, equals(2));
      expect(stats.timeouts, equals(0));
      expect(stats.workers, hasLength(1));
      expect(stats.workers.single.pendingRequests, equals(1));
      expect(stats.latencyMaxMicros, greaterThanOrEqualTo(0));

      async.dispose();
      await expectLater(blocked, throwsA(isA<AsyncError>()));
    });

    test('reports timeout counter', () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(milliseconds: 20),
        isolateEntry: fakeWorkerNoResponse,
      );
      await async.initialize();

      await expectLater(async.connect('DSN=Test'), throwsA(isA<AsyncError>()));

      final stats = async.getWorkerPoolStats();
      expect(stats.timeouts, equals(1));
      expect(stats.pendingRequests, equals(0));
      async.dispose();
    });

    test('reports fallback to blocking query path', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerAsyncExecuteParamsFallback,
      );
      await async.initialize();

      final data = await async.executeQueryParamBuffer(
        10,
        'SELECT ?',
        Uint8List.fromList([1]),
      );

      expect(data, equals(Uint8List.fromList([9])));
      expect(async.getWorkerPoolStats().fallbacksToBlocking, equals(1));
      async.dispose();
    });

    test('reports cancel and latency metrics', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerCancelSupport,
      );
      await async.initialize();

      final cancelled = await async.cancelStatement(42);

      expect(cancelled, isFalse);
      final stats = async.getWorkerPoolStats();
      expect(stats.cancelAttempts, equals(1));
      expect(stats.cancelUnsupported, equals(1));
      expect(stats.workers.single.latencyMaxMicros, greaterThan(0));
      async.dispose();
    });

    test('controlled worker exit fails pending and clears affinities',
        () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 5),
        isolateEntry: fakeWorkerControlledExit,
      );
      await async.initialize();

      final connId = await async.connect('DSN=test');
      final stmtId = await async.prepare(connId, 'SELECT 1');
      expect(stmtId, equals(8001));
      expect(async.affinityEntryCountForTesting, greaterThan(0));

      final pending = async.executeQueryParams(
        connId,
        'SELECT 1',
        const <ParamValue>[],
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      async.failWorkerForTesting(0);
      await expectLater(pending, throwsA(isA<AsyncError>()));
      expect(async.affinityEntryCountForTesting, equals(0));
      async.dispose();
    });
  });
}

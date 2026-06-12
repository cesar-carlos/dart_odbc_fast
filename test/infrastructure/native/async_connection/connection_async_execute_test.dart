import 'dart:typed_data';

import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';
import 'fake_workers.dart';

void main() {
  loadTestEnv();
  group('AsyncNativeOdbcConnection async execute', () {
    test('should run async execute lifecycle via worker messages', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerAsyncExecuteSupport,
      );
      await async.initialize();

      final requestId = await async.executeAsyncStart(1, 'SELECT 1');
      final status = await async.asyncPoll(requestId);
      final data = await async.asyncGetResult(requestId);
      final cancelled = await async.asyncCancel(requestId);
      final freed = await async.asyncFree(requestId);

      expect(requestId, equals(1234));
      expect(status, equals(1));
      expect(data, isNotNull);
      expect(data, isNotEmpty);
      expect(cancelled, isTrue);
      expect(freed, isTrue);

      async.dispose();
    });

    test('executeAsync should poll until ready and return data', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerAsyncExecuteDelayedReady,
      );
      await async.initialize();

      final data = await async.executeAsync(
        1,
        'SELECT 1',
        pollInterval: const Duration(milliseconds: 1),
        timeout: const Duration(seconds: 1),
      );

      expect(data, isNotNull);
      expect(data, equals(Uint8List.fromList([7, 8, 9])));
      async.dispose();
    });

    test('executeQueryParamBuffer should use async params lifecycle', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerAsyncExecuteParamsSupport,
      );
      await async.initialize();

      final data = await async.executeQueryParamBuffer(
        1,
        'SELECT ?',
        Uint8List.fromList([1, 2, 3]),
        timeout: const Duration(seconds: 1),
      );

      expect(data, equals(Uint8List.fromList([3])));
      async.dispose();
    });

    test(
      'executeQueryParamBuffer uses async path for columnar encoding '
      'without blocking fallback',
      () async {
        final async = AsyncNativeOdbcConnection(
          isolateEntry: fakeWorkerAsyncExecuteParamsColumnarSupport,
        );
        await async.initialize();

        final data = await async.executeQueryParamBuffer(
          1,
          'SELECT ?',
          Uint8List.fromList([1, 2, 3]),
          resultEncoding: ResultEncoding.columnar,
        );

        expect(data, equals(Uint8List.fromList([3, 1])));
        expect(async.getWorkerPoolStats().fallbacksToBlocking, equals(0));
        async.dispose();
      },
    );

    test('executeQueryParamBuffer falls back when async params is unavailable',
        () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerAsyncExecuteParamsFallback,
      );
      await async.initialize();

      final data = await async.executeQueryParamBuffer(
        1,
        'SELECT ?',
        Uint8List.fromList([1, 2, 3]),
      );

      expect(data, equals(Uint8List.fromList([9])));
      async.dispose();
    });
  });
  group('adaptive poll backoff', () {
    test(
      'should_resolve_result_after_multiple_pending_polls',
      () async {
        // Worker returns pending 4 times then ready; verifies the adaptive
        // poll loop terminates correctly and returns the result.
        final async = AsyncNativeOdbcConnection(
          isolateEntry: fakeWorkerPendingThenReady,
        );
        await async.initialize();

        final result = await async.executeAsync(1, 'SELECT 1');
        // The fake worker returns an arbitrary non-null payload.
        expect(result, isNotNull);

        async.dispose();
      },
    );

    test(
      'should_complete_faster_than_fixed_max_poll_interval_per_pending_poll',
      () async {
        // With 4 pending polls before ready, adaptive backoff (1→2→4→8 ms)
        // should finish in well under 4 × 10 ms = 40 ms.
        // Allow 500 ms for CI headroom; the goal is to detect regressions that
        // restore a large fixed sleep per pending poll.
        final async = AsyncNativeOdbcConnection(
          isolateEntry: fakeWorkerPendingThenReady,
        );
        await async.initialize();

        final sw = Stopwatch()..start();
        final result = await async.executeAsync(1, 'SELECT 1');
        sw.stop();

        expect(result, isNotNull);
        // 4 pending polls × 10 ms = 40 ms with the old fixed interval.
        // Adaptive should be well below 40 ms even on slow CI.
        expect(sw.elapsedMilliseconds, lessThan(500));

        async.dispose();
      },
    );
  });
}

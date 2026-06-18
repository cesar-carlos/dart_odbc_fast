import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/odbc_fast.dart';
import 'package:odbc_fast/odbc_fast_native.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';
import 'fake_workers.dart';

void main() {
  loadTestEnv();
  group('AsyncNativeOdbcConnection', () {
    late AsyncNativeOdbcConnection async;

    setUp(() {
      async = AsyncNativeOdbcConnection();
    });

    test('workerCount defaults to one and rejects invalid values', () {
      expect(async.workerCount, equals(1));
      expect(
        () => AsyncNativeOdbcConnection(workerCount: 0),
        throwsArgumentError,
      );
    });

    test('maxPendingRequests defaults to null and rejects invalid values', () {
      expect(async.maxPendingRequests, isNull);
      expect(async.backpressureMode, equals(AsyncBackpressureMode.failFast));
      expect(async.backpressureTimeout, isNull);
      expect(
        () => AsyncNativeOdbcConnection(maxPendingRequests: 0),
        throwsArgumentError,
      );
      expect(
        () => AsyncNativeOdbcConnection(
          backpressureTimeout: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
    });

    test('should_initialize_without_blocking_event_loop', () async {
      final initFuture = async.initialize();
      final eventLoopResponded = Completer<void>();
      Timer(const Duration(milliseconds: 1), eventLoopResponded.complete);

      await expectLater(
        eventLoopResponded.future,
        completes,
        reason: 'Main isolate event loop must stay responsive during worker '
            'spawn and ODBC init',
      );

      expect(await initFuture, isTrue);
      expect(async.isInitialized, isTrue);
    });

    test('should return true when already initialized', () async {
      await async.initialize();
      expect(async.isInitialized, isTrue);

      // Second initialize should return true immediately
      final result = await async.initialize();
      expect(result, isTrue);
    });

    test('should throw AsyncError when connecting without initialization',
        () async {
      // Skip initialization
      expect(
        () => async.connect('DSN=Test'),
        throwsA(isA<AsyncError>()),
      );
    });

    test('should throw AsyncError with notInitialized code', () async {
      try {
        await async.connect('DSN=Test');
        fail('Should have thrown AsyncError');
      } on AsyncError catch (e) {
        expect(e.code, equals(AsyncErrorCode.notInitialized));
        expect(e.message, contains('not initialized'));
      }
    });

    test(
      'should not block main thread during long operation',
      () async {
        await async.initialize();

        // Simulate UI thread responsiveness
        final uiResponder = Completer<void>();
        Timer(const Duration(milliseconds: 50), uiResponder.complete);

        // Run operation (even if it takes time)
        // Note: This will fail with invalid DSN but that's ok for the test
        try {
          await async.connect('DSN=InvalidDSNThatMightTimeout');
        } on Exception {
          // Expected - invalid DSN
        }

        // UI should have responded even if connect took time
        await expectLater(uiResponder.future, completes);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'should NOT block main thread while a worker request is pending',
      () async {
        async.dispose();
        async = AsyncNativeOdbcConnection(isolateEntry: fakeWorkerDelayedQuery);
        await async.initialize();
        final connId = await async.connect('DSN=fake');

        final timerCompleted = Completer<void>();
        Timer(const Duration(milliseconds: 100), timerCompleted.complete);

        final queryFuture = async.executeQueryParams(
          connId,
          'SELECT 1',
          [],
        );

        await expectLater(
          timerCompleted.future,
          completes,
          reason: 'Timer should complete before long query finishes',
        );
        await queryFuture;
        await async.disconnect(connId);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'should execute independent queries concurrently across workers',
      () async {
        async.dispose();
        async = AsyncNativeOdbcConnection(
          workerCount: 3,
          isolateEntry: fakeWorkerDelayedQuery,
        );
        await async.initialize();
        final connId1 = await async.connect('DSN=fake');
        final connId2 = await async.connect('DSN=fake');
        final connId3 = await async.connect('DSN=fake');

        final results = await Future.wait([
          async.executeQueryParams(
            connId1,
            'SELECT 1',
            [],
          ),
          async.executeQueryParams(
            connId2,
            'SELECT 1',
            [],
          ),
          async.executeQueryParams(
            connId3,
            'SELECT 1',
            [],
          ),
        ]);
        final stats = async.getWorkerPoolStats();

        expect(results, everyElement(equals(Uint8List.fromList([1]))));
        expect(stats.workers, hasLength(3));
        expect(
          stats.workers.map((worker) => worker.totalRouted),
          everyElement(greaterThanOrEqualTo(3)),
          reason: 'Each fake query should keep connection affinity on a '
              'different worker; wall-clock timing is covered by stress tests.',
        );
        await async.disconnect(connId1);
        await async.disconnect(connId2);
        await async.disconnect(connId3);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test('should handle errors gracefully', () async {
      await async.initialize();

      // Try to get error when there is none
      final error = await async.getError();
      expect(error, isA<String>());

      // Try to disconnect with invalid connection ID
      final result = await async.disconnect(999);
      expect(result, isA<bool>());
    });

    test('should expose streaming methods as Stream', () {
      final stream1 = async.streamQuery(1, 'SELECT 1', chunkSize: 100);
      final stream2 = async.streamQueryBatched(1, 'SELECT 1', fetchSize: 100);

      // Should return Stream objects (not Future)
      expect(stream1, isA<Stream<ParsedRowBuffer>>());
      expect(stream2, isA<Stream<ParsedRowBuffer>>());
    });

    test('should call dispose on underlying connection', () {
      // Dispose should be synchronous and call through to native
      async.dispose();

      // If it didn't throw, it worked
      expect(true, isTrue);
    });

    test('should handle getStructuredError async', () async {
      await async.initialize();

      // Get structured error - may or may not be null depending on ODBC state
      final error = await async.getStructuredError();

      // Just verify it completes successfully and returns the correct type
      expect(error, isA<StructuredError?>());
    });

    test('should handle getStructuredErrorForConnection async', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerStructuredErrorSupport,
      );
      await async.initialize();

      final error = await async.getStructuredErrorForConnection(77);

      expect(error, isNotNull);
      expect(error!.message, equals('connection failure 77'));
      expect(error.sqlStateString, equals('08S01'));
      expect(error.nativeCode, equals(701));
      async.dispose();
    });
  });
}

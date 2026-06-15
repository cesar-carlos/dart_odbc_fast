/// Lifecycle tests for async worker channel, pool, and initialization.
library;

import 'package:odbc_fast/odbc_fast_native.dart';
import 'package:test/test.dart';

import '../../helpers/load_env.dart';
import 'async_connection/fake_workers.dart';

void main() {
  loadTestEnv();

  group('AsyncNativeOdbcConnection worker lifecycle', () {
    test('should_return_false_when_worker_initialize_fails', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerInitFailure,
      );

      final initialized = await async.initialize();

      expect(initialized, isFalse);
      expect(async.isInitialized, isFalse);
      async.dispose();
    });

    test(
      'should_complete_pending_with_workerTerminated_on_shutdown',
      () async {
        final async = AsyncNativeOdbcConnection(
          requestTimeout: const Duration(seconds: 60),
          isolateEntry: fakeWorkerNoResponse,
        );
        await async.initialize();

        final connectFuture = async.connect('DSN=blocked');
        async.dispose();

        await expectLater(
          connectFuture,
          throwsA(
            isA<AsyncError>().having(
              (e) => e.code,
              'code',
              AsyncErrorCode.workerTerminated,
            ),
          ),
        );
      },
    );

    test('should_fail_fast_when_maxPendingRequests_exceeded', () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 60),
        isolateEntry: fakeWorkerNoResponse,
        maxPendingRequests: 1,
      );
      await async.initialize();

      final blocked = async.connect('DSN=blocked');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await expectLater(
        async.connect('DSN=overflow'),
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

    test('should_wait_for_slot_when_backpressure_mode_is_waitForSlot',
        () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 5),
        isolateEntry: fakeWorkerPoolRoutingSupport,
        maxPendingRequests: 1,
        backpressureMode: AsyncBackpressureMode.waitForSlot,
      );
      await async.initialize();

      final first = async.connect('DSN=slow');
      final second = async.connect('DSN=fast');
      final ids = await Future.wait<int>([first, second]);

      expect(ids, hasLength(2));
      expect(ids.first, isNot(equals(ids.last)));
      async.dispose();
    });
  });
}

import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';
import 'fake_workers.dart';

void main() {
  loadTestEnv();
  group('AsyncNativeOdbcConnection recovery guards', () {
    test('dispose should not trigger auto-recovery', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerStreamingSupport,
        autoRecoverOnWorkerCrash: true,
      );
      await async.initialize();

      async.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(async.isInitialized, isFalse);
    });

    test('recoverWorker should be safe when called concurrently', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerStreamingSupport,
      );
      await async.initialize();

      await Future.wait([
        async.recoverWorker(),
        async.recoverWorker(),
        async.recoverWorker(),
      ]);

      expect(async.isInitialized, isTrue);
      final chunks = await async.streamQuery(1, 'SELECT 1').toList();
      expect(chunks, isNotEmpty);
      async.dispose();
    });
  });
  group('worker recovery callback', () {
    test('should_invoke_onWorkerRecovered_after_recovery_completes', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerFastLifecycle,
        autoRecoverOnWorkerCrash: true,
      );
      await async.initialize();

      var recoveryCount = 0;
      async.onWorkerRecovered = () => recoveryCount++;

      // Manual recovery cycle exercises the same code path as auto-recovery.
      await async.recoverWorker();

      expect(recoveryCount, equals(1));
      expect(async.isInitialized, isTrue);
      async.dispose();
    });

    test('should_swallow_callback_exceptions_during_recovery', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerFastLifecycle,
        autoRecoverOnWorkerCrash: true,
      );
      await async.initialize();

      async.onWorkerRecovered = () {
        throw StateError('boom');
      };

      // The throw must not break the recovery cycle: pool stays initialized.
      await async.recoverWorker();
      expect(async.isInitialized, isTrue);
      async.dispose();
    });

    test('should_clear_callback_when_set_to_null', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerFastLifecycle,
        autoRecoverOnWorkerCrash: true,
      );
      await async.initialize();

      var calls = 0;
      async
        ..onWorkerRecovered = (() => calls++)
        ..onWorkerRecovered = null;

      await async.recoverWorker();
      expect(calls, equals(0));
      async.dispose();
    });
  });
}

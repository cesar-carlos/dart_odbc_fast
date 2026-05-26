// Backpressure modes + worker recovery callback.
//
// Demonstrates three opt-in `AsyncNativeOdbcConnection` knobs:
//   * `AsyncBackpressureMode.failFast`   — extra requests above
//     `maxPendingRequests` fail immediately with
//     `AsyncErrorCode.resourceExhausted`.
//   * `AsyncBackpressureMode.waitForSlot` — extra requests queue FIFO until a
//     slot opens (or `backpressureTimeout`).
//   * `onWorkerRecovered`                — fires after auto-recovery so
//     higher layers can wipe stale connection / statement / txn ids.
//
// Run: dart run example/backpressure_modes_demo.dart
//
// Requires ODBC_TEST_DSN or ODBC_DSN in .env or the environment.

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  await _runFailFastDemo(dsn);
  await _runWaitForSlotDemo(dsn);
  await _runRecoveryCallbackDemo(dsn);
}

Future<void> _runFailFastDemo(String dsn) async {
  AppLogger.info('--- failFast: extras rejected with resourceExhausted ---');

  // Tiny pending cap (2) so the demo always saturates the queue. Every
  // subsequent request fails immediately instead of waiting.
  final async = AsyncNativeOdbcConnection(
    maxPendingRequests: 2,
    requestTimeout: const Duration(seconds: 10),
  );
  if (!await async.initialize()) {
    AppLogger.severe('failFast init failed');
    return;
  }

  try {
    final connId = await async.connect(dsn);
    if (connId == 0) {
      AppLogger.warning('failFast connect failed: ${await async.getError()}');
      return;
    }

    // Fire many concurrent queries; only 2 fit the cap. The rest must throw
    // synchronously (within their Future chain) with resourceExhausted.
    final futures = List.generate(
      10,
      (_) => async
          .executeAsync(connId, 'SELECT 1 AS v')
          .then<String>((_) => 'ok')
          .catchError(
            (Object e) => e is AsyncError ? 'rejected:${e.code.name}' : 'err',
          ),
    );
    final results = await Future.wait(futures);
    final ok = results.where((r) => r == 'ok').length;
    final rejected =
        results.where((r) => r.startsWith('rejected:resourceExhausted')).length;
    AppLogger.info(
      'failFast: ok=$ok rejected=$rejected (cap=2)',
    );

    await async.disconnect(connId);
  } finally {
    async.dispose();
  }
}

Future<void> _runWaitForSlotDemo(String dsn) async {
  AppLogger.info('--- waitForSlot: extra requests queue FIFO ---');

  final async = AsyncNativeOdbcConnection(
    maxPendingRequests: 2,
    backpressureMode: AsyncBackpressureMode.waitForSlot,
    backpressureTimeout: const Duration(seconds: 5),
    requestTimeout: const Duration(seconds: 10),
  );
  if (!await async.initialize()) {
    AppLogger.severe('waitForSlot init failed');
    return;
  }

  try {
    final connId = await async.connect(dsn);
    if (connId == 0) {
      AppLogger.warning(
        'waitForSlot connect failed: ${await async.getError()}',
      );
      return;
    }

    // Same fan-out, different mode: every call eventually completes (no
    // resourceExhausted), but some had to wait briefly for a free slot.
    final stopwatch = Stopwatch()..start();
    final futures = List.generate(
      10,
      (_) => async
          .executeAsync(connId, 'SELECT 1 AS v')
          .then<String>((_) => 'ok')
          .catchError(
            (Object e) => e is AsyncError ? 'failed:${e.code.name}' : 'err:$e',
          ),
    );
    final results = await Future.wait(futures);
    stopwatch.stop();
    final ok = results.where((r) => r == 'ok').length;
    final elapsedMs = stopwatch.elapsedMilliseconds;
    AppLogger.info(
      'waitForSlot: ok=$ok/10 in ${elapsedMs}ms (all serviced)',
    );

    await async.disconnect(connId);
  } finally {
    async.dispose();
  }
}

Future<void> _runRecoveryCallbackDemo(String dsn) async {
  AppLogger.info('--- onWorkerRecovered: callback wiring ---');

  // The repository auto-registers its own callback when wrapped by
  // OdbcRepositoryImpl. This demo wires a *user* callback directly on the
  // async connection to show the public API. In production, prefer letting
  // the repository do it — application-level state can subscribe to its
  // own signal once the repository invalidates ids.
  final async = AsyncNativeOdbcConnection(
    autoRecoverOnWorkerCrash: true,
    requestTimeout: const Duration(seconds: 10),
  );
  if (!await async.initialize()) {
    AppLogger.severe('recovery init failed');
    return;
  }

  var recoveryNotifications = 0;
  async.onWorkerRecovered = () {
    recoveryNotifications++;
    AppLogger.info(
      'recovery callback fired (#$recoveryNotifications) — clear stale ids '
      'and reconnect application state here',
    );
  };

  try {
    final connId = await async.connect(dsn);
    if (connId == 0) {
      AppLogger.warning('recovery connect failed: ${await async.getError()}');
      return;
    }

    // Manual recovery cycle exercises the same path as auto-recovery on a
    // worker crash — pool is disposed, re-initialized, then the callback
    // fires once before normal traffic resumes.
    await async.recoverWorker();
    AppLogger.info(
      'recovery: callback called $recoveryNotifications time(s) '
      '(expected: 1)',
    );

    // Pre-recovery connection ids are no longer valid; reconnect.
    final freshId = await async.connect(dsn);
    if (freshId != 0) {
      await async.disconnect(freshId);
    }
  } finally {
    async.dispose();
  }
}

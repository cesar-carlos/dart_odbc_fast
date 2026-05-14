// High-concurrency async worker pool demo.
// Run: dart run example/high_concurrency_worker_pool_demo.dart

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show BinaryProtocolParser;
import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  const workerCount = 4;
  const connectionCount = 4;
  const queryCount = 16;

  final async = AsyncNativeOdbcConnection(
    workerCount: workerCount,
    maxPendingRequests: connectionCount * 4,
    requestTimeout: const Duration(seconds: 30),
  );

  if (!await async.initialize()) {
    AppLogger.severe('ODBC environment initialization failed');
    return;
  }

  final connections = <int>[];
  try {
    for (var i = 0; i < connectionCount; i++) {
      final connId = await async.connect(dsn);
      if (connId == 0) {
        throw StateError('Connection #$i failed: ${await async.getError()}');
      }
      connections.add(connId);
    }

    AppLogger.info(
      'Worker pool ready: workers=${async.workerCount}, '
      'connections=${connections.length}, queries=$queryCount',
    );

    final serialElapsed = await _measure(() async {
      for (var i = 0; i < queryCount; i++) {
        await _runSelectOne(async, connections[i % connections.length]);
      }
    });

    final parallelElapsed = await _measure(() async {
      await Future.wait(
        List.generate(queryCount, (i) {
          final connId = connections[i % connections.length];
          return _runSelectOne(async, connId);
        }),
      );
    });

    AppLogger.info('Serial elapsed: ${serialElapsed.inMilliseconds} ms');
    AppLogger.info('Parallel elapsed: ${parallelElapsed.inMilliseconds} ms');
    final stats = async.getWorkerPoolStats();
    AppLogger.info(
      'Worker stats: routed=${stats.totalRouted}, '
      'pending=${stats.pendingRequests}, active=${stats.activeRequests}, '
      'timeouts=${stats.timeouts}, fallbacks=${stats.fallbacksToBlocking}',
    );
    AppLogger.info(
      'Expected: parallel time trends toward the slowest in-flight query '
      'when the workload uses multiple connections and workerCount > 1.',
    );
  } finally {
    for (final connId in connections) {
      await async.disconnect(connId);
    }
    async.dispose();
  }
}

Future<Duration> _measure(Future<void> Function() action) async {
  final stopwatch = Stopwatch()..start();
  await action();
  stopwatch.stop();
  return stopwatch.elapsed;
}

Future<int> _runSelectOne(
  AsyncNativeOdbcConnection async,
  int connId,
) async {
  final data = await async.executeQueryParams(
    connId,
    'SELECT 1 AS value',
    const <ParamValue>[],
  );
  if (data == null) {
    throw StateError('Query failed: ${await async.getError()}');
  }
  final parsed = BinaryProtocolParser.parse(data);
  return parsed.rowCount;
}

// High-concurrency async worker pool demo.
// Run: dart run example/high_concurrency_worker_pool_demo.dart

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';
import 'package:odbc_fast/odbc_fast_native.dart';

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
  final query = _envOr('ODBC_CONCURRENCY_QUERY', 'SELECT 1 AS value');

  final async = AsyncNativeOdbcConnection(
    workerCount: workerCount,
    maxPendingRequests: connectionCount * 4,
    requestTimeout: const Duration(seconds: 30),
  );

  if (!await async.initialize()) {
    stderr.writeln('ODBC environment initialization failed');
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

    _log(
      'Worker pool ready: workers=${async.workerCount}, '
      'connections=${connections.length}, queries=$queryCount',
    );
    _log(
      'workerCount=$workerCount starts Dart worker isolates. Use multiple '
      'connections to reduce the same-worker/driver bottleneck; one '
      'connection remains serialized by the native connection mutex.',
    );
    _log(
      'Query: $query',
    );

    final serialElapsed = await _measure(() async {
      for (var i = 0; i < queryCount; i++) {
        await _runQuery(async, connections[i % connections.length], query);
      }
    });

    final parallelElapsed = await _measure(() async {
      await Future.wait(
        List.generate(queryCount, (i) {
          final connId = connections[i % connections.length];
          return _runQuery(async, connId, query);
        }),
      );
    });

    _log('Serial elapsed: ${serialElapsed.inMilliseconds} ms');
    _log('Parallel elapsed: ${parallelElapsed.inMilliseconds} ms');
    final stats = async.getWorkerPoolStats();
    _log(
      'Worker stats: routed=${stats.totalRouted}, '
      'pending=${stats.pendingRequests}, active=${stats.activeRequests}, '
      'timeouts=${stats.timeouts}, fallbacks=${stats.fallbacksToBlocking}',
    );
    _log(
      'Per worker routed: '
      '${stats.workers.map((worker) => worker.totalRouted).join(', ')}',
    );
    _log(
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

Future<int> _runQuery(
  AsyncNativeOdbcConnection async,
  int connId,
  String query,
) async {
  final data = await async.executeQueryParams(
    connId,
    query,
    const <ParamValue>[],
  );
  if (data == null) {
    throw StateError('Query failed: ${await async.getError()}');
  }
  final parsed = BinaryProtocolParser.parse(data);
  return parsed.rowCount;
}

String _envOr(String name, String fallback) {
  final value = Platform.environment[name];
  if (value != null && value.isNotEmpty) return value;
  return fallback;
}

void _log(String message) {
  stdout.writeln(message);
  AppLogger.info(message);
}

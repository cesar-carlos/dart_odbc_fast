import 'dart:math' as math;

import 'package:odbc_fast/odbc_fast.dart' hide DatabaseType;
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Async worker pool real DSN stress', () {
    test(
      'runs slow queries on multiple connections near max individual time',
      () async {
        final dsn = getTestEnv('ODBC_TEST_DSN') ?? getTestEnv('ODBC_DSN');
        final slowQuery = _slowQueryForDsn(dsn);
        if (dsn == null || slowQuery == null) return;

        final async = AsyncNativeOdbcConnection(workerCount: 3);
        await async.initialize();
        final connections = <int>[];

        try {
          for (var i = 0; i < 3; i++) {
            connections.add(await async.connect(dsn));
          }

          final serialElapsed = await _measure(() async {
            for (final connId in connections) {
              await _runQuery(async, connId, slowQuery);
            }
          });

          final parallelElapsed = await _measure(() {
            return Future.wait(
              connections.map((connId) => _runQuery(async, connId, slowQuery)),
            );
          });

          expect(
            parallelElapsed.inMilliseconds,
            lessThan((serialElapsed.inMilliseconds * 0.75).round()),
            reason: 'Parallel multi-connection elapsed should be materially '
                'lower than the local serial baseline.',
          );
        } finally {
          for (final connId in connections) {
            await async.disconnect(connId);
          }
          async.dispose();
        }
      },
      skip: _runAsyncWorkerPoolStress
          ? null
          : 'Stress test - set RUN_SKIPPED_TESTS=1, '
              'ODBC_ASYNC_WORKER_POOL_STRESS=1, and a real DSN',
      timeout: const Timeout(Duration(seconds: 20)),
    );

    test(
      'serializes concurrent slow queries on the same connection',
      () async {
        final dsn = getTestEnv('ODBC_TEST_DSN') ?? getTestEnv('ODBC_DSN');
        final slowQuery = _slowQueryForDsn(dsn);
        if (dsn == null || slowQuery == null) return;

        final async = AsyncNativeOdbcConnection(workerCount: 3);
        await async.initialize();
        var connId = 0;

        try {
          connId = await async.connect(dsn);
          final serialElapsed = await _measure(() async {
            for (var i = 0; i < 3; i++) {
              await _runQuery(async, connId, slowQuery);
            }
          });

          final concurrentElapsed = await _measure(() {
            return Future.wait(
              List.generate(3, (_) => _runQuery(async, connId, slowQuery)),
            );
          });

          expect(
            concurrentElapsed.inMilliseconds,
            greaterThan((serialElapsed.inMilliseconds * 0.75).round()),
            reason: 'Same-connection work must retain affinity and serialize '
                'close to the local serial baseline.',
          );
        } finally {
          if (connId > 0) {
            await async.disconnect(connId);
          }
          async.dispose();
        }
      },
      skip: _runAsyncWorkerPoolStress
          ? null
          : 'Stress test - set RUN_SKIPPED_TESTS=1, '
              'ODBC_ASYNC_WORKER_POOL_STRESS=1, and a real DSN',
      timeout: const Timeout(Duration(seconds: 25)),
    );

    test(
      'native pool honors explicit in-flight limit under async workers',
      () async {
        final dsn = getTestEnv('ODBC_TEST_DSN') ?? getTestEnv('ODBC_DSN');
        if (dsn == null) return;

        const poolSize = 4;
        const taskCount = 12;
        const maxInFlight = 4;
        final async = AsyncNativeOdbcConnection(
          workerCount: 4,
          maxPendingRequests: poolSize * 4,
        );
        await async.initialize();
        var poolId = 0;
        var currentInFlight = 0;
        var peakInFlight = 0;

        try {
          poolId = await async.poolCreate(dsn, poolSize);
          expect(poolId, greaterThan(0));

          await _runLimited<void>(taskCount, maxInFlight, (index) async {
            currentInFlight++;
            peakInFlight = math.max(peakInFlight, currentInFlight);
            var connId = 0;
            try {
              connId = await async.poolGetConnection(poolId);
              await _runQuery(async, connId, 'SELECT 1 AS value');
            } finally {
              currentInFlight--;
              if (connId > 0) {
                await async.poolReleaseConnection(connId);
              }
            }
          });

          expect(peakInFlight, lessThanOrEqualTo(maxInFlight));
          final state = await async.poolGetState(poolId);
          expect(state?.idle, equals(poolSize));
        } finally {
          if (poolId > 0) {
            await async.poolClose(poolId);
          }
          async.dispose();
        }
      },
      skip: _runAsyncWorkerPoolStress
          ? null
          : 'Stress test - set RUN_SKIPPED_TESTS=1, '
              'ODBC_ASYNC_WORKER_POOL_STRESS=1, and a real DSN',
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}

bool get _runAsyncWorkerPoolStress {
  final raw = getTestEnv('ODBC_ASYNC_WORKER_POOL_STRESS');
  final normalized = raw?.trim().toLowerCase();
  return runStressTests &&
      (normalized == '1' || normalized == 'true' || normalized == 'yes');
}

String? _slowQueryForDsn(String? dsn) {
  final explicit = getTestEnv('ODBC_TEST_SLOW_QUERY');
  if (explicit != null && explicit.isNotEmpty) {
    return explicit;
  }
  switch (detectDatabaseType(dsn)) {
    case DatabaseType.sqlServer:
      return "WAITFOR DELAY '00:00:01'; SELECT 1 AS value";
    case DatabaseType.postgresql:
      return 'SELECT pg_sleep(1), 1 AS value';
    case DatabaseType.mysql:
      return 'SELECT SLEEP(1) AS waited, 1 AS value';
    case DatabaseType.oracle:
    case DatabaseType.sqlite:
    case DatabaseType.unknown:
      return null;
  }
}

Future<void> _runQuery(
  AsyncNativeOdbcConnection async,
  int connId,
  String sql,
) async {
  final data = await async.executeQueryParams(
    connId,
    sql,
    const <ParamValue>[],
  );
  if (data == null) {
    throw StateError('Query failed');
  }
}

Future<Duration> _measure(Future<void> Function() action) async {
  final stopwatch = Stopwatch()..start();
  await action();
  stopwatch.stop();
  return stopwatch.elapsed;
}

Future<List<T>> _runLimited<T>(
  int count,
  int maxInFlight,
  Future<T> Function(int index) task,
) async {
  final results = List<T?>.filled(count, null);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= count) return;
      results[index] = await task(index);
    }
  }

  await Future.wait(List.generate(maxInFlight, (_) => worker()));
  return results.cast<T>();
}

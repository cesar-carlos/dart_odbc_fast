// Independent short queries with separate checkouts and bounded work.
// A single ODBC connection remains serialized even with multiple workers.
// Run: dart run example/high_concurrency_pool_demo.dart
// Optional: ODBC_CONCURRENCY_QUERY, ODBC_CONCURRENCY_TASKS (default 24).

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() => withExamplePool((locator, service, poolId) async {
      final tuning = locator.resolvedUsageProfile;
      final tasks = positiveExampleEnvInt('ODBC_CONCURRENCY_TASKS', 24);
      final query =
          Platform.environment['ODBC_CONCURRENCY_QUERY'] ?? 'SELECT 1 AS value';
      var completed = 0;
      var rows = 0;
      final stopwatch = Stopwatch()..start();
      await runBoundedExampleTasks(tasks, locator.recommendedPoolMaxSize,
          (index) async {
        final connection = (await service.poolGetConnection(
          poolId,
          options: locator.recommendedConnectionOptions,
        ))
            .getOrThrow();
        try {
          final result =
              (await locator.queryService.executeQueryFor(connection, query))
                  .getOrThrow();
          rows += result.rowCount;
          completed++;
        } finally {
          reportExampleCleanup(
            await service.poolReleaseConnection(connection.id),
            'poolReleaseConnection',
          );
        }
      });
      stopwatch.stop();
      final state = (await service.poolGetState(poolId)).getOrThrow();
      reportExampleProgress(
          'completed=$completed rows=$rows workers=${tuning.workerCount} '
          'maxInFlight=${locator.recommendedPoolMaxSize} '
          'idle=${state.idle}/${state.size} '
          'elapsedUs=${stopwatch.elapsedMicroseconds}');
      // Timeout can leave native work running. Do not retry SQL or reuse a
      // checkout after release; reconciliation/explicit shutdown owns
      // uncertainty.
    });

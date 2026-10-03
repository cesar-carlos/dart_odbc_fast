// Native parallel bulk via the async Result service and a bounded payload.
// Measure against bulk_insert_demo.dart on the same driver/workload.
// Run: dart run example/bulk_insert_parallel_demo.dart
// SQL Server sample DDL. Creates/drops a uniquely named demo table.
// Optional: ODBC_BULK_ROWS (10000), ODBC_BULK_BATCH_ROWS (5000),
// ODBC_BULK_PARALLELISM (4). Parallel batches are not one atomic transaction.

import 'bulk_insert_demo.dart' show buildBulkDemoBatch, withBulkDemoTable;
import 'common.dart';

Future<void> main() => withExamplePool((locator, service, poolId) async {
      final rows = positiveExampleEnvInt('ODBC_BULK_ROWS', 10000);
      final batchRows = positiveExampleEnvInt('ODBC_BULK_BATCH_ROWS', 5000);
      final requested = positiveExampleEnvInt('ODBC_BULK_PARALLELISM', 4);
      // Keep one checkout for setup/cleanup; the other slots execute native
      // bulk.
      final available = locator.recommendedPoolMaxSize - 1;
      final parallelism = requested < available ? requested : available;
      if (parallelism < 1) {
        throw StateError('Parallel bulk needs at least two pool slots.');
      }
      final connection = (await service.poolGetConnection(poolId)).getOrThrow();
      try {
        final table =
            'odbc_bulk_parallel_demo_${DateTime.now().microsecondsSinceEpoch}';
        await withBulkDemoTable(service, connection.id, table, () async {
          var inserted = 0;
          var batches = 0;
          final stopwatch = Stopwatch()..start();
          for (var offset = 0; offset < rows; offset += batchRows) {
            final remaining = rows - offset;
            final count = remaining < batchRows ? remaining : batchRows;
            final builder = buildBulkDemoBatch(table, offset, count);
            inserted += (await service.bulkInsertParallel(
              poolId,
              table,
              builder.columnNames,
              builder.build(),
              count,
              parallelism: parallelism,
            ))
                .getOrThrow();
            batches++;
          }
          stopwatch.stop();
          reportExampleProgress(
              'bulkInsertParallel rows=$inserted batches=$batches '
              'parallelism=$parallelism batchRows=$batchRows '
              'elapsedUs=${stopwatch.elapsedMicroseconds}');
        });
      } finally {
        reportExampleCleanup(
          await service.poolReleaseConnection(connection.id),
          'poolReleaseConnection',
        );
      }
      // Failures can contain partial insert counts. Do not automatically
      // replay.
    });

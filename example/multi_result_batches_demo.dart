// Large multi-result cursors without coalescing continuation rows.
// Run: dart run example/multi_result_batches_demo.dart
// Optional: ODBC_MULTI_BATCH_QUERY, ODBC_MULTI_BATCH_FETCH (default 1000).
// The sample requires multi-statement driver support (e.g. SQL Server).

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() => withExampleConnection(
      (locator, service, connection) async {
        final sql = Platform.environment['ODBC_MULTI_BATCH_QUERY'] ??
            'SELECT 1 AS id UNION ALL SELECT 2 UNION ALL SELECT 3; '
                "SELECT 'summary' AS kind;";
        final fetchSize = positiveExampleEnvInt('ODBC_MULTI_BATCH_FETCH', 1000);
        var batches = 0;
        var resultSets = 0;
        var rows = 0;
        var affectedRows = 0;
        await for (final result in service.streamQueryMultiBatches(
          connection.id,
          sql,
          fetchSize: fetchSize,
          chunkSize: locator.recommendedStreamChunkSizeBytes,
        )) {
          final item = result.getOrThrow();
          if (item.resultSet case final batch?) {
            if (!item.isContinuationBatch) resultSets++;
            rows += batch.rowCount;
            batches++;
            // Process/await this batch here; never retain earlier batches.
          } else if (item.rowCount case final count?) {
            if (count >= 0) {
              affectedRows += count; // -1 means unknown to the driver.
            }
          }
        }
        reportExampleProgress(
            'resultSets=$resultSets batches=$batches rows=$rows '
            'knownAffectedRows=$affectedRows fetchSize=$fetchSize');
        // streamQueryMulti coalesces a complete cursor. It retains continuation
        // rows, so use it only when each result set fits in memory.
      },
      profile: OdbcUsageProfile.balancedServer,
    );

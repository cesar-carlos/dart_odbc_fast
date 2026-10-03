// Large numeric scans: aggregate typed arrays one batch at a time.
// Run: dart run example/stream_query_columnar_demo.dart
// Optional: ODBC_COLUMNAR_QUERY returning a numeric score column.

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';
import 'typed_columnar_demo.dart' show defaultColumnarQuery, sumNonNullScores;

Future<void> main() => withExampleConnection(
      (locator, service, connection) async {
        var rows = 0;
        var batches = 0;
        num total = 0;
        final stopwatch = Stopwatch()..start();
        await for (final result in locator.queryService.streamQueryColumnarFor(
          connection,
          Platform.environment['ODBC_COLUMNAR_QUERY'] ?? defaultColumnarQuery,
          chunkSize: locator.recommendedStreamChunkSizeBytes,
        )) {
          final batch = result.getOrThrow();
          total += sumNonNullScores(batch);
          rows += batch.rowCount;
          batches++;
        }
        stopwatch.stop();
        reportExampleProgress('rows=$rows batches=$batches scoreSum=$total '
            'chunkBytes=${locator.recommendedStreamChunkSizeBytes} '
            'elapsedUs=${stopwatch.elapsedMicroseconds}');
      },
      profile: OdbcUsageProfile.balancedServer,
    );

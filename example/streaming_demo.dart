// Large row reads without collecting batches or logging every row.
// Run: dart run example/streaming_demo.dart
// Optional: ODBC_STREAM_QUERY, ODBC_STREAM_FETCH_SIZE (default 1000).
// Supply a read-only query for your schema to exercise a large scan.

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() => withExampleConnection(
      (locator, service, connection) async {
        final sql = Platform.environment['ODBC_STREAM_QUERY'] ??
            'SELECT 1 AS id UNION ALL SELECT 2 UNION ALL SELECT 3';
        final fetchSize = positiveExampleEnvInt('ODBC_STREAM_FETCH_SIZE', 1000);
        var batches = 0;
        var rows = 0;
        final stopwatch = Stopwatch()..start();
        await for (final result in locator.queryService.streamQueryFor(
          connection,
          sql,
          fetchSize: fetchSize,
          chunkSize: locator.recommendedStreamChunkSizeBytes,
        )) {
          final batch = result.getOrThrow();
          // Await asynchronous consumers here. Avoid toList and unawaited row
          // work.
          rows += batch.rowCount;
          batches++;
        }
        stopwatch.stop();
        reportExampleProgress(
            'rows=$rows batches=$batches fetchSize=$fetchSize '
            'chunkBytes=${locator.recommendedStreamChunkSizeBytes} '
            'elapsedUs=${stopwatch.elapsedMicroseconds}');
      },
      profile: OdbcUsageProfile.balancedServer,
    );

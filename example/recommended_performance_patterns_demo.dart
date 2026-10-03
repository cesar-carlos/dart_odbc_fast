// Read-only entry point. The tiny query illustrates API shape, not throughput.
// Run: dart run example/recommended_performance_patterns_demo.dart
// Optional: ODBC_PERF_QUERY,
// ODBC_PERF_PROFILE=balanced|balancedServer|highThroughput

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() async {
  stdout
    ..writeln('Performance patterns:')
    ..writeln(
      '  Repeated SQL -> prepare once, bind ParamValue, execute many.',
    )
    ..writeln(
      '  Large row reads -> streamQuery, process one batch at a time.',
    )
    ..writeln('  Numeric analytics -> streamQueryColumnar, typed arrays.')
    ..writeln('  Large multi-result -> streamQueryMultiBatches.')
    ..writeln(
      '  Inserts -> bulkInsert; measure before choosing parallel bulk.',
    )
    ..writeln('  Independent requests -> pool + bounded concurrency.')
    ..writeln('  Repeated column lookup -> result.reader() once per batch.');
  final profile =
      switch (Platform.environment['ODBC_PERF_PROFILE']?.toLowerCase()) {
    'balanced' => OdbcUsageProfile.balanced,
    'highthroughput' => OdbcUsageProfile.highThroughput,
    _ => OdbcUsageProfile.balancedServer,
  };
  await withExampleConnection(
    (locator, service, connection) async {
      final tuning = locator.resolvedUsageProfile;
      final sql = Platform.environment['ODBC_PERF_QUERY'] ??
          'SELECT CAST(1 AS INTEGER) AS id';
      var rows = 0;
      var batches = 0;
      final stopwatch = Stopwatch()..start();
      if (tuning.recommendedResultEncoding.isColumnar) {
        await for (final result in service.streamQueryColumnar(
          connection.id,
          sql,
          chunkSize: locator.recommendedStreamChunkSizeBytes,
        )) {
          final batch = result.getOrThrow();
          rows += batch.rowCount;
          batches++;
        }
      } else {
        await for (final result in service.streamQuery(
          connection.id,
          sql,
          chunkSize: locator.recommendedStreamChunkSizeBytes,
        )) {
          final batch = result.getOrThrow();
          rows += batch.rowCount;
          batches++;
        }
      }
      stopwatch.stop();
      reportExampleProgress(
        'profile=${tuning.profile.name} workers=${tuning.workerCount} '
        'rows=$rows batches=$batches '
        'elapsedUs=${stopwatch.elapsedMicroseconds}',
      );
    },
    profile: profile,
  );
}

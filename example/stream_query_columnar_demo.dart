// Columnar streaming via `streamQueryColumnar` on the server preset.
//
// `OdbcUsageProfile.balancedServer` enables async workers, a larger native
// pool, and `recommendedResultEncoding: columnar`. This demo passes
// `chunkSize: locator.recommendedStreamChunkSizeBytes` (1 MiB on server
// presets) so batched streaming matches PERFORMANCE.md guidance.
//
// Run: dart run example/stream_query_columnar_demo.dart
//
// Requires ODBC_TEST_DSN or ODBC_DSN in .env or the environment.
// Optional: ODBC_COLUMNAR_QUERY="SELECT 1 AS id, 42.5 AS score"

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final sql = Platform.environment['ODBC_COLUMNAR_QUERY'] ??
      "SELECT 1 AS id, 42.5 AS score, 'alpha' AS label";

  final locator = ServiceLocator()
    ..initialize(profile: OdbcUsageProfile.balancedServer);
  final queries = locator.queryService;
  final tuning = locator.resolvedUsageProfile;

  AppLogger.info(
    'profile=${tuning.profile.name} workers=${tuning.workerCount} '
    'encoding=${tuning.recommendedResultEncoding.name}',
  );

  final service = locator.asyncService;
  final init = await service.initialize();
  if (init.isError()) {
    AppLogger.severe('initialize failed: ${init.exceptionOrNull()}');
    locator.shutdown();
    return;
  }

  final connect = await service.connect(
    dsn,
    options: locator.recommendedConnectionOptions,
  );
  if (connect.isError()) {
    AppLogger.severe('connect failed: ${connect.exceptionOrNull()}');
    locator.shutdown();
    return;
  }

  final conn = connect.getOrThrow();
  final chunkSize = locator.recommendedStreamChunkSizeBytes;
  AppLogger.info('streamChunkSizeBytes=$chunkSize (profile recommendation)');
  try {
    var chunkIndex = 0;
    await for (final chunk in queries.streamQueryColumnarFor(
      conn,
      sql,
      chunkSize: chunkSize,
    )) {
      chunk.fold(
        (typed) {
          AppLogger.info(
            'chunk $chunkIndex: rowCount=${typed.rowCount} '
            'columns=${typed.columns.map((c) => c.name).join(", ")}',
          );
          final ids = typed.column<TypedColumnInt32>('id');
          final scores = typed.column<TypedColumnFloat64>('score');
          for (var i = 0; i < typed.rowCount; i++) {
            final id = ids.isNullAt(i) ? null : ids.values[i];
            final score = scores.isNullAt(i) ? null : scores.values[i];
            AppLogger.info('  row $i: id=$id score=$score');
          }
        },
        (error) =>
            AppLogger.warning('streamQueryColumnar chunk failed: $error'),
      );
      chunkIndex++;
    }
    AppLogger.info('stream completed ($chunkIndex chunk(s))');
  } finally {
    await service.disconnect(conn.id);
    locator.shutdown();
  }
}

// Bounded-memory streaming for multi-result statements.
//
// Use `streamQueryMultiBatches` when one result set can be large and the
// consumer can handle each fetch batch independently. Unlike
// `streamQueryMulti`, it never joins continuation batches, so peak decoded
// rows are bounded by `fetchSize`. Use `streamQueryMulti` when the simpler
// coalesced result-set view is more important than that memory bound.
//
// Run: dart run example/multi_result_batches_demo.dart
//
// Requires ODBC_TEST_DSN or ODBC_DSN. The sample uses a SQL Server-style
// multi-statement batch; provide a dialect-appropriate query through
// ODBC_MULTI_BATCH_QUERY when needed. ODBC_MULTI_BATCH_FETCH controls the
// per-cursor batch size (default 1000); lower it only to visualize
// continuations.

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

const _defaultQuery = '''
  SELECT 1 AS id UNION ALL SELECT 2 UNION ALL SELECT 3;
  SELECT 'summary' AS kind;
''';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final locator = ServiceLocator()
    ..initialize(profile: OdbcUsageProfile.balancedServer);
  final service = locator.asyncService;
  final tuning = locator.resolvedUsageProfile;
  final fetchSize = _positiveEnvInt('ODBC_MULTI_BATCH_FETCH', 1000);
  final chunkSize = locator.recommendedStreamChunkSizeBytes;

  final init = await service.initialize();
  if (init.isError()) {
    AppLogger.severe('initialize failed: ${init.exceptionOrNull()}');
    locator.shutdown();
    return;
  }

  final connected = await service.connect(
    dsn,
    options: locator.recommendedConnectionOptions,
  );
  final connection = connected.getOrNull();
  if (connection == null) {
    AppLogger.severe('connect failed: ${connected.exceptionOrNull()}');
    locator.shutdown();
    return;
  }

  final sql = Platform.environment['ODBC_MULTI_BATCH_QUERY'] ?? _defaultQuery;
  try {
    AppLogger.info(
      'Streaming uncoalesced MULT batches: profile=${tuning.profile.name} '
      'fetchSize=$fetchSize chunkSize=$chunkSize',
    );

    var itemCount = 0;
    var batchCount = 0;
    var rowCount = 0;
    await for (final result in service.streamQueryMultiBatches(
      connection.id,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    )) {
      result.fold(
        (item) {
          itemCount++;
          if (item.isResultSet) {
            final rows = item.resultSet!.rowCount;
            batchCount++;
            rowCount += rows;
            AppLogger.info(
              'result-set batch=$batchCount rows=$rows '
              'continuation=${item.isContinuationBatch}',
            );
          } else {
            AppLogger.info('row-count=${item.rowCount}');
          }
        },
        (error) => AppLogger.severe('streamQueryMultiBatches failed: $error'),
      );
    }
    AppLogger.info(
      'Done: items=$itemCount resultSetBatches=$batchCount rows=$rowCount. '
      'Rows from a continued cursor were processed without coalescing.',
    );
  } finally {
    await service.disconnect(connection.id);
    locator.shutdown();
  }
}

int _positiveEnvInt(String key, int fallback) {
  final parsed = int.tryParse(Platform.environment[key] ?? '');
  return parsed != null && parsed > 0 ? parsed : fallback;
}

// Recommended performance patterns — decision map in executable form.
//
// Workload → API (see also specialized demos):
//   small query     → executeQuery / executeQueryParamValues
//   large read      → streamQuery / streamQueryNamed / streamQueryColumnar
//                     Prefer chunkSize ≥ batch wire (often 1–4 MiB).
//                     Columnar helps typed analytics paths; full SELECT *
//                     text materialize may stay faster on row-major — see
//                     doc/PERFORMANCE.md "Streaming SELECT headroom".
//   medium insert   → bulkInsert (~hundreds)
//   large insert    → bulkInsertParallel (example/bulk_insert_parallel_demo.dart)
//   server/async    → OdbcUsageProfile.balancedServer or highThroughput
//   app default     → OdbcUsageProfile.balanced (this demo)
//
// Optional:
//   ODBC_PERF_PROFILE=balancedServer|highThroughput|balanced
//
// Run: dart run example/recommended_performance_patterns_demo.dart
//
// Requires ODBC_TEST_DSN or ODBC_DSN. Bulk sample DDL targets SQL Server;
// other dialects still exercise query + stream paths.

import 'dart:io';
import 'dart:typed_data';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

const _bulkTable = 'perf_patterns_bulk_demo';
const _bulkRows = 50;

OdbcUsageProfile _profileFromEnv() {
  final raw = Platform.environment['ODBC_PERF_PROFILE']?.trim().toLowerCase();
  return switch (raw) {
    'balancedserver' || 'balanced_server' => OdbcUsageProfile.balancedServer,
    'highthroughput' || 'high_throughput' => OdbcUsageProfile.highThroughput,
    _ => OdbcUsageProfile.balanced,
  };
}

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final profile = _profileFromEnv();
  final locator = ServiceLocator()..initialize(profile: profile);
  final service = locator.service;
  final tuning = locator.resolvedUsageProfile;

  AppLogger.info(
    'profile=${tuning.profile.name} async=${tuning.useAsync} '
    'workers=${tuning.workerCount} '
    'encoding=${tuning.recommendedResultEncoding.name}',
  );
  AppLogger.info(
    'Pointers: streaming_demo / stream_query_columnar_demo / '
    'bulk_insert_parallel_demo / high_concurrency_pool_demo / '
    'named_parameters_demo (prepared reuse)',
  );

  final init = await service.initialize();
  if (init.isError()) {
    AppLogger.severe('initialize failed: ${init.exceptionOrNull()}');
    locator.shutdown();
    return;
  }

  final connResult = await service.connect(
    dsn,
    options: locator.recommendedConnectionOptions,
  );
  if (connResult.isError()) {
    AppLogger.severe('connect failed: ${connResult.exceptionOrNull()}');
    locator.shutdown();
    return;
  }

  final conn = connResult.getOrThrow();
  try {
    await _smallQuery(service, conn.id);
    await _streamRead(service, conn.id);
    await _bulkInsertSample(service, conn.id);
  } finally {
    await service.disconnect(conn.id);
  }

  locator.shutdown();
}

Future<void> _smallQuery(IOdbcService service, String connId) async {
  final result = await service.executeQueryParamValues(
    connId,
    "SELECT 1 AS id, 'small-query' AS kind",
    const <ParamValue>[],
  );
  result.fold(
    (r) => AppLogger.info(
      'small query (executeQuery*): '
      'rows=${r.rowCount} cols=${r.columns.length}',
    ),
    (e) => AppLogger.warning('small query failed: $e'),
  );
}

Future<void> _streamRead(IOdbcService service, String connId) async {
  // Service streamQuery uses batched streaming by default.
  var chunks = 0;
  var rows = 0;
  await for (final item in service.streamQuery(
    connId,
    'SELECT 1 AS id UNION ALL SELECT 2 UNION ALL SELECT 3',
  )) {
    item.fold(
      (r) {
        chunks++;
        rows += r.rowCount;
      },
      (e) => AppLogger.warning('stream chunk failed: $e'),
    );
  }
  AppLogger.info(
    'large-read pattern (streamQuery → batched): '
    'chunks=$chunks rows=$rows '
    '(scale: streamQueryColumnar + chunkSize≥1MiB; see PERFORMANCE.md)',
  );
}

Future<void> _bulkInsertSample(IOdbcService service, String connId) async {
  const ddl = '''
    IF OBJECT_ID('$_bulkTable', 'U') IS NOT NULL DROP TABLE $_bulkTable;
    CREATE TABLE $_bulkTable (
      id INT NOT NULL PRIMARY KEY,
      name NVARCHAR(64) NOT NULL
    )
  ''';
  final created = await service.executeQueryParamValues(
    connId,
    ddl,
    const <ParamValue>[],
  );
  if (created.isError()) {
    AppLogger.info(
      'bulkInsert sample skipped (DDL not supported on this dialect): '
      '${created.exceptionOrNull()}',
    );
    return;
  }

  final ids = Int32List.fromList(
    List<int>.generate(_bulkRows, (i) => i + 1),
  );
  final names = List<String>.generate(_bulkRows, (i) => 'row-${i + 1}');
  final builder = BulkInsertBuilder()
      .table(_bulkTable)
      .addColumnInt32('id', ids)
      .addColumnText('name', names, maxLen: 64);

  final inserted = await service.bulkInsert(
    connId,
    builder.tableName,
    builder.columnNames,
    builder.build(),
    builder.rowCount,
  );
  inserted.fold(
    (n) => AppLogger.info(
      'medium insert (bulkInsert): inserted=$n '
      '(scale up → bulk_insert_parallel_demo)',
    ),
    (e) => AppLogger.warning('bulkInsert failed: $e'),
  );

  await service.executeQueryParamValues(
    connId,
    "IF OBJECT_ID('$_bulkTable', 'U') IS NOT NULL DROP TABLE $_bulkTable",
    const <ParamValue>[],
  );
}

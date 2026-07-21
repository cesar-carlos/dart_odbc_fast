// Demonstrates opt-in result encodings for parameterized query execution.
//
// With `OdbcUsageProfile.balanced` / legacy, row-major remains the default.
// Server presets (`balancedServer`, `highThroughput`) already recommend
// columnar via `recommendedResultEncoding` — see
// example/stream_query_columnar_demo.dart. Prefer columnar after validating
// the target workload and driver; use `columnarCompressed` only when wire
// size matters more than CPU.
//
// Run:
//   dart run example/columnar_result_encoding_demo.dart
//
// Optional:
//   ODBC_TEST_DSN=...
//   ODBC_COLUMNAR_QUERY="SELECT 1 AS id, 'alpha' AS label"

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

void main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final sql = Platform.environment['ODBC_COLUMNAR_QUERY'] ??
      "SELECT 1 AS id, 'alpha' AS label";

  final locator = ServiceLocator()
    ..initialize(profile: OdbcUsageProfile.balanced);
  final service = locator.service;

  if ((await service.initialize()).isError()) {
    AppLogger.severe('initialize failed');
    locator.shutdown();
    return;
  }
  final connect = await service.connect(
    dsn,
    options: locator.recommendedConnectionOptions,
  );
  if (connect.isError()) {
    AppLogger.severe('connect: ${connect.exceptionOrNull()}');
    return;
  }

  final connId = connect.getOrThrow().id;
  try {
    for (final encoding in ResultEncoding.values) {
      final result = await service.executeQueryParamValuesFromObjects(
        connId,
        sql,
        const <Object?>[],
        resultEncoding: encoding,
      );
      result.fold(
        (ok) => AppLogger.info(
          '${encoding.name}: rowCount=${ok.rowCount}, '
          'columns=${ok.columns.length}, '
          'firstRow=${ok.rows.isEmpty ? const <Object?>[] : ok.rows.first}',
        ),
        (error) => AppLogger.warning(
          '${encoding.name} failed: $error. '
          'For compressed columnar, confirm the loaded native library exports '
          'odbc_columnar_decompress.',
        ),
      );
    }
  } finally {
    await service.disconnect(connId);
    locator.shutdown();
  }
}

// Typed columnar query demo: `executeQueryColumnarParamValues`,
// `streamQueryColumnar`, and `TypedColumnarResult` consumption.
//
// Under `balanced` / legacy, row-major `QueryResult` remains the default.
// For server workloads prefer `OdbcUsageProfile.balancedServer` (or
// `highThroughput`) so columnar is the recommended encoding without per-call
// overrides — see example/stream_query_columnar_demo.dart. Use the typed
// columnar surface when numeric pipelines benefit from `Int32List` /
// `Int64List` / `Float64List` instead of per-cell `dynamic` boxing.
//
// Run: dart run example/typed_columnar_demo.dart
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
    ..initialize(profile: OdbcUsageProfile.balanced);
  final service = locator.service;

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

  final connId = connect.getOrThrow().id;
  try {
    final result = await service.executeQueryColumnarParamValues(
      connId,
      sql,
      params: const <ParamValue>[],
    );

    result.fold(
      (typed) {
        AppLogger.info('rowCount=${typed.rowCount}');
        final columnSummary =
            typed.columns.map((c) => '${c.name}:${c.kind.name}').join(', ');
        AppLogger.info('columns=$columnSummary');

        final ids = typed.column<TypedColumnInt32>('id');
        final scores = typed.column<TypedColumnFloat64>('score');
        final labels = typed.column<TypedColumnObject<String>>('label');

        for (var i = 0; i < typed.rowCount; i++) {
          final id = ids.isNullAt(i) ? null : ids.values[i];
          final score = scores.isNullAt(i) ? null : scores.values[i];
          final label = labels.values[i];
          AppLogger.info('  row $i: id=$id score=$score label=$label');
        }
      },
      (error) => AppLogger.warning('columnar query failed: $error'),
    );

    var chunkIndex = 0;
    await for (final chunk in service.streamQueryColumnar(connId, sql)) {
      chunk.fold(
        (typed) {
          AppLogger.info(
            'streamQueryColumnar chunk $chunkIndex: rowCount=${typed.rowCount}',
          );
          final ids = typed.column<TypedColumnInt32>('id');
          if (typed.rowCount > 0 && !ids.isNullAt(0)) {
            AppLogger.info('  first id=${ids.values[0]}');
          }
        },
        (error) =>
            AppLogger.warning('streamQueryColumnar chunk failed: $error'),
      );
      chunkIndex++;
    }
  } finally {
    await service.disconnect(connId);
    locator.shutdown();
  }
}

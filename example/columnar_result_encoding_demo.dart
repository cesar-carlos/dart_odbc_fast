// QueryResult wire clamp vs typed columnar APIs.
//
// Row-shaped APIs (`executeQuery*`, `streamQuery*`) always request row-major
// wire via `forQueryResultWire` — passing `ResultEncoding.columnar` there is
// a no-op. End-to-end columnar requires `executeQueryColumnar*` /
// `streamQueryColumnar*` (see also stream_query_columnar_demo.dart).
//
// Native encoding matrix including `columnarCompressed`:
//   example/async_concurrency_benchmark.dart
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
    AppLogger.info(
      'forQueryResultWire(columnar)='
      '${forQueryResultWire(ResultEncoding.columnar).name} '
      '(QueryResult paths always clamp columnar requests)',
    );

    final clamped = await service.executeQueryParamValuesFromObjects(
      connId,
      sql,
      const <Object?>[],
      resultEncoding: ResultEncoding.columnar,
    );
    clamped.fold(
      (ok) => AppLogger.info(
        'QueryResult + resultEncoding=columnar (clamped to row-major): '
        'rowCount=${ok.rowCount}, firstRow='
        '${ok.rows.isEmpty ? const <Object?>[] : ok.rows.first}',
      ),
      (error) => AppLogger.warning('clamped QueryResult path failed: $error'),
    );

    final typed = await service.executeQueryColumnarParamValues(
      connId,
      sql,
      params: const <ParamValue>[],
    );
    typed.fold(
      (ok) {
        final ids = ok.column<TypedColumnInt32>('id');
        final labels = ok.column<TypedColumnObject<String>>('label');
        AppLogger.info(
          'executeQueryColumnarParamValues (true columnar wire): '
          'rowCount=${ok.rowCount}, '
          'id0=${ids.isNullAt(0) ? null : ids.values[0]}, '
          'label0=${labels.values[0]}',
        );
      },
      (error) => AppLogger.warning(
        'typed columnar failed: $error. '
        'Confirm the native library exports columnar decode paths.',
      ),
    );

    AppLogger.info(
      'For stream + server preset: stream_query_columnar_demo.dart. '
      'For columnarCompressed native matrix: async_concurrency_benchmark.dart.',
    );
  } finally {
    await service.disconnect(connId);
    locator.shutdown();
  }
}

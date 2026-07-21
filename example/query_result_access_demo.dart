// QueryResultAccess demo: typed row/column helpers on row-major QueryResult.
//
// Use when you already have a `QueryResult` from `executeQueryParamValues` (or
// legacy execute paths) and want `columnIndex`, `cell`, `rowAsMap`, and scalar
// getters without manual index bookkeeping.
//
// Run: dart run example/query_result_access_demo.dart
//
// Requires ODBC_TEST_DSN or ODBC_DSN in .env or the environment.

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

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
    final result = await service.executeQueryParamValues(
      connId,
      "SELECT 1 AS id, 42.5 AS score, 'alpha' AS label",
      const <ParamValue>[],
    );

    result.fold(
      (qr) {
        AppLogger.info(
          'rowCount=${qr.rowCount} hasColumn(id)=${qr.hasColumn('id')}',
        );

        final idIdx = qr.columnIndex('id');
        AppLogger.info('columnIndex(id)=$idIdx');

        final cellId = qr.cell(0, 'id');
        AppLogger.info('cell(0, id)=$cellId');

        final row0 = qr.rowAsMap(0);
        AppLogger.info('rowAsMap(0)=$row0');

        final first = qr.firstRowOrNull;
        AppLogger.info('firstRowOrNull=$first');

        final id = qr.scalar<int>('id');
        final score = qr.scalar<double>('score');
        final label = qr.scalar<String>('label');
        AppLogger.info('scalar row0: id=$id score=$score label=$label');

        final ids = qr.columnValues<int>('id');
        AppLogger.info('columnValues(id)=$ids');

        for (final rowMap in qr.rowsAsMaps) {
          AppLogger.info('rowsAsMaps entry=$rowMap');
        }
      },
      (error) => AppLogger.warning('query failed: $error'),
    );
  } finally {
    await service.disconnect(connId);
    locator.shutdown();
  }
}

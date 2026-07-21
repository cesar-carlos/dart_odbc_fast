// Single-connection bulk insert demo (~500 rows).
//
// Uses column-oriented `BulkInsertBuilder.addColumnInt32` +
// `addColumnText` and the high-level `IOdbcService.bulkInsert` API.
// Prefer this over row-by-row INSERT for medium batches. For larger payloads
// (>~1k rows) scale out with `bulkInsertParallel` /
// example/bulk_insert_parallel_demo.dart (often ~3× on a small pool).
//
// Run: dart run example/bulk_insert_demo.dart
//
// Requires ODBC_TEST_DSN or ODBC_DSN and a SQL Server–compatible driver for
// the sample DDL (IDENTITY column). Adjust table DDL for other dialects.

import 'dart:typed_data';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

const _rowCount = 500;
const _table = 'bulk_insert_demo';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final locator = ServiceLocator()..initialize();
  final service = locator.syncService;

  if ((await service.initialize()).isError()) {
    AppLogger.severe('initialize failed');
    return;
  }

  final connect = await service.connect(dsn);
  if (connect.isError()) {
    AppLogger.severe('connect failed: ${connect.exceptionOrNull()}');
    return;
  }

  final connId = connect.getOrThrow().id;
  try {
    await _ensureTable(service, connId);

    final builder = _buildPayload();
    final sw = Stopwatch()..start();
    final result = await service.bulkInsert(
      connId,
      builder.tableName,
      builder.columnNames,
      builder.build(),
      builder.rowCount,
    );
    sw.stop();

    result.fold(
      (inserted) => AppLogger.info(
        'bulkInsert inserted $inserted rows in '
        '${sw.elapsedMilliseconds} ms (payload=$_rowCount rows)',
      ),
      (error) => AppLogger.severe('bulkInsert failed: $error'),
    );
  } finally {
    await service.disconnect(connId);
  }
}

BulkInsertBuilder _buildPayload() {
  final ids = Int32List.fromList(List<int>.generate(_rowCount, (i) => i + 1));
  final names = List<String>.generate(_rowCount, (i) => 'row-${i + 1}');
  return BulkInsertBuilder()
      .table(_table)
      .addColumnInt32('id', ids)
      .addColumnText('name', names, maxLen: 64);
}

Future<void> _ensureTable(OdbcService service, String connId) async {
  const ddl = '''
    IF OBJECT_ID('bulk_insert_demo', 'U') IS NOT NULL
      DROP TABLE bulk_insert_demo;

    CREATE TABLE bulk_insert_demo (
      id INT NOT NULL PRIMARY KEY,
      name NVARCHAR(64) NOT NULL
    )
  ''';

  final created = await service.executeQueryParamValues(
    connId,
    ddl,
    const <ParamValue>[],
  );
  created.fold(
    (_) => AppLogger.info('Table ready: $_table'),
    (e) => AppLogger.warning('DDL failed: $e'),
  );
}

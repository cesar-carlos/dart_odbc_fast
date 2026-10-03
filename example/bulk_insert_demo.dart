// Bulk insertion with bounded payload memory and no row-by-row SQL.
// Run: dart run example/bulk_insert_demo.dart
// SQL Server sample DDL. Creates/drops a uniquely named demo table.
// Optional: ODBC_BULK_ROWS (default 10000), ODBC_BULK_BATCH_ROWS (default
// 1000).

import 'dart:typed_data';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() => withExampleConnection(
      (locator, service, connection) async {
        final rows = positiveExampleEnvInt('ODBC_BULK_ROWS', 10000);
        final batchRows = positiveExampleEnvInt('ODBC_BULK_BATCH_ROWS', 1000);
        final table = 'odbc_bulk_demo_${DateTime.now().microsecondsSinceEpoch}';
        await withBulkDemoTable(service, connection.id, table, () async {
          var inserted = 0;
          var batches = 0;
          final stopwatch = Stopwatch()..start();
          for (var offset = 0; offset < rows; offset += batchRows) {
            final remaining = rows - offset;
            final count = remaining < batchRows ? remaining : batchRows;
            final builder = buildBulkDemoBatch(table, offset, count);
            inserted += (await service.bulkInsert(
              connection.id,
              table,
              builder.columnNames,
              builder.build(),
              count,
            ))
                .getOrThrow();
            batches++;
          }
          stopwatch.stop();
          reportExampleProgress(
            'bulkInsert rows=$inserted batches=$batches batchRows=$batchRows '
            'elapsedUs=${stopwatch.elapsedMicroseconds}',
          );
        });
      },
      profile: OdbcUsageProfile.balancedServer,
    );

/// Builds only one batch; numeric columns avoid per-cell ParamValue objects.
BulkInsertBuilder buildBulkDemoBatch(String table, int offset, int count) {
  final ids = Int32List(count);
  for (var row = 0; row < count; row++) {
    ids[row] = offset + row + 1;
  }
  return BulkInsertBuilder()
      .table(table)
      .addColumnInt32('id', ids)
      .addColumnText(
        'name',
        List<String>.generate(count, (row) => 'row-${offset + row + 1}'),
        maxLen: 64,
      );
}

/// Only generated identifiers are allowed; values are carried in bulk buffers.
Future<void> withBulkDemoTable(
  IOdbcService service,
  String connectionId,
  String table,
  Future<void> Function() action,
) async {
  if (!RegExp(r'^odbc_bulk_(?:parallel_)?demo_[0-9]+$').hasMatch(table)) {
    throw ArgumentError.value(
      table,
      'table',
      'Expected a generated demo name.',
    );
  }
  (await service.executeQuery(
    'CREATE TABLE [$table] (id INT NOT NULL PRIMARY KEY, name '
    'NVARCHAR(64) NOT NULL)',
    connectionId: connectionId,
  ))
      .getOrThrow();
  try {
    await action();
  } finally {
    reportExampleCleanup(
      await service.executeQuery(
        'DROP TABLE [$table]',
        connectionId: connectionId,
      ),
      'dropBulkDemoTable',
    );
  }
}

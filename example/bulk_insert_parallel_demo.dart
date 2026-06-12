// Parallel bulk insert demo for large batches (>1k rows).
// Run: dart run example/bulk_insert_parallel_demo.dart
//
// Requires ODBC_DSN or ODBC_TEST_DSN and a SQL Server–compatible driver for
// the sample DDL (IDENTITY column). Adjust table DDL for other dialects.

import 'dart:typed_data';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

const _rowCount = 2000;
const _parallelism = 4;
const _poolSize = 4;
const _table = 'bulk_parallel_demo';

void main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final native = NativeOdbcConnection();
  if (!native.initialize()) {
    AppLogger.severe('ODBC environment initialization failed');
    return;
  }

  final pool = native.createConnectionPool(dsn, _poolSize);
  if (pool == null) {
    AppLogger.severe('Pool creation failed: ${native.getError()}');
    return;
  }

  try {
    await _ensureTable(native, pool);
    final payload = _buildPayload();
    AppLogger.info(
      'Payload ready: $_rowCount rows, ${payload.lengthInBytes} bytes',
    );

    final sw = Stopwatch()..start();
    final inserted = pool.bulkInsertParallel(
      _table,
      const ['name'],
      payload,
      parallelism: _parallelism,
    );
    sw.stop();

    if (inserted < 0) {
      AppLogger.severe('bulkInsertParallel failed');
      return;
    }

    AppLogger.info(
      'bulkInsertParallel inserted $inserted rows in '
      '${sw.elapsedMilliseconds} ms '
      '(parallelism=$_parallelism, poolSize=$_poolSize)',
    );
  } finally {
    pool.close();
  }
}

Uint8List _buildPayload() {
  final builder = BulkInsertBuilder()
    ..table(_table)
    ..addColumn('name', BulkColumnType.text, maxLen: 64);

  for (var i = 1; i <= _rowCount; i++) {
    builder.addRow(['row-$i']);
  }

  return builder.build();
}

Future<void> _ensureTable(
  NativeOdbcConnection native,
  ConnectionPool pool,
) async {
  const ddl = '''
    IF OBJECT_ID('bulk_parallel_demo', 'U') IS NOT NULL
      DROP TABLE bulk_parallel_demo;

    CREATE TABLE bulk_parallel_demo (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(64) NOT NULL
    )
  ''';

  final connId = pool.getConnection();
  if (connId == 0) {
    AppLogger.warning('Failed to get pooled connection: ${native.getError()}');
    return;
  }

  try {
    final stmt = native.prepare(connId, ddl);
    if (stmt == 0) {
      AppLogger.warning('Prepare failed: ${native.getError()}');
      return;
    }
    try {
      native.executePrepared(stmt, const <ParamValue>[], 0, 1000);
    } finally {
      native.closeStatement(stmt);
    }
  } finally {
    pool.releaseConnection(connId);
  }
}

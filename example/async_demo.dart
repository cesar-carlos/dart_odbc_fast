// Async ODBC demo using AsyncNativeOdbcConnection.
// Run: dart run example/async_demo.dart

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show BinaryProtocolParser;
import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

void main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final async = AsyncNativeOdbcConnection(
    requestTimeout: const Duration(seconds: 30),
    autoRecoverOnWorkerCrash: true,
  );

  if (!await async.initialize()) {
    AppLogger.severe('ODBC environment initialization failed');
    return;
  }

  final connId = await async.connect(dsn);
  if (connId == 0) {
    AppLogger.severe('Connection failed: ${await async.getError()}');
    async.dispose();
    return;
  }

  AppLogger.info('Connected: $connId');

  try {
    await _createTestTable(async, connId);
    await _insertData(async, connId);
    await _queryData(async, connId);
  } finally {
    await async.disconnect(connId);
    async.dispose();
    AppLogger.info('Disconnected and disposed');
  }
}

Future<void> _createTestTable(
  AsyncNativeOdbcConnection async,
  int connId,
) async {
  const sql = '''
    IF OBJECT_ID('async_test_table', 'U') IS NOT NULL
      DROP TABLE async_test_table;

    CREATE TABLE async_test_table (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL,
      value DECIMAL(10,2)
    )
  ''';

  final stmt = await async.prepare(connId, sql);
  if (stmt == 0) {
    AppLogger.warning('Prepare failed: ${await async.getError()}');
    return;
  }

  try {
    final result =
        await async.executePrepared(stmt, const <ParamValue>[], 0, 1000);
    if (result == null) {
      AppLogger.warning(
        'Table creation failed: ${await async.getError()}',
      );
      return;
    }
    AppLogger.info('Table ready: async_test_table');
  } finally {
    await async.closeStatement(stmt);
  }
}

Future<void> _insertData(
  AsyncNativeOdbcConnection async,
  int connId,
) async {
  const sql = 'INSERT INTO async_test_table (name, value) VALUES (?, ?)';
  final stmt = await async.prepare(connId, sql);
  if (stmt == 0) {
    AppLogger.warning('Prepare failed: ${await async.getError()}');
    return;
  }

  try {
    for (var i = 1; i <= 3; i++) {
      final result = await async.executePrepared(
        stmt,
        [
          ParamValueString('Item_$i'),
          ParamValueDecimal((i * 10.5).toStringAsFixed(2)),
        ],
        0,
        1000,
      );

      if (result == null) {
        AppLogger.warning(
          'Insert failed on item $i: ${await async.getError()}',
        );
        return;
      }
    }
    AppLogger.info('Inserted 3 rows');
  } finally {
    await async.closeStatement(stmt);
  }
}

Future<void> _queryData(
  AsyncNativeOdbcConnection async,
  int connId,
) async {
  const sql = 'SELECT id, name, value FROM async_test_table ORDER BY id';
  final stmt = await async.prepare(connId, sql);
  if (stmt == 0) {
    AppLogger.warning('Prepare failed: ${await async.getError()}');
    return;
  }

  try {
    final data =
        await async.executePrepared(stmt, const <ParamValue>[], 0, 1000);
    if (data == null) {
      AppLogger.warning('Query failed: ${await async.getError()}');
      return;
    }

    final parsed = BinaryProtocolParser.parse(data);
    AppLogger.info('Query OK: rowCount=${parsed.rowCount}');
    for (final row in parsed.rows) {
      AppLogger.fine('Row: $row');
    }
  } finally {
    await async.closeStatement(stmt);
  }
}

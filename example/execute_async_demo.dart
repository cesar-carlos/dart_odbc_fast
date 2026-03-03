// Demo of executeAsync and streamAsync (raw async API).
// Run: dart run example/execute_async_demo.dart
//
// Shows direct use of:
// - executeAsync(connId, sql) for non-blocking single-query execution
// - streamAsync(connId, sql) for non-blocking streaming of large results

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
    await _setupTable(async, connId);
    await _runExecuteAsync(async, connId);
    await _runStreamAsync(async, connId);
  } finally {
    await async.disconnect(connId);
    async.dispose();
    AppLogger.info('Disconnected and disposed');
  }
}

Future<void> _setupTable(
  AsyncNativeOdbcConnection async,
  int connId,
) async {
  const ddl = '''
    IF OBJECT_ID('execute_async_demo_table', 'U') IS NOT NULL
      DROP TABLE execute_async_demo_table;

    CREATE TABLE execute_async_demo_table (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL,
      value DECIMAL(10,2)
    )
  ''';

  final stmt = await async.prepare(connId, ddl);
  if (stmt == 0) {
    AppLogger.warning('Prepare failed: ${await async.getError()}');
    return;
  }

  try {
    final result =
        await async.executePrepared(stmt, const <ParamValue>[], 0, 1000);
    if (result == null) {
      AppLogger.warning('DDL failed: ${await async.getError()}');
      return;
    }
  } finally {
    await async.closeStatement(stmt);
  }

  const insertSql =
      'INSERT INTO execute_async_demo_table (name, value) VALUES (?, ?)';
  final insertStmt = await async.prepare(connId, insertSql);
  if (insertStmt == 0) {
    AppLogger.warning('Insert prepare failed: ${await async.getError()}');
    return;
  }

  try {
    for (var i = 1; i <= 5; i++) {
      final r = await async.executePrepared(
        insertStmt,
        [
          ParamValueString('Item_$i'),
          ParamValueDecimal((i * 10.0).toStringAsFixed(2)),
        ],
        0,
        1000,
      );
      if (r == null) {
        AppLogger.warning('Insert failed: ${await async.getError()}');
        return;
      }
    }
    AppLogger.info('Table ready with 5 rows');
  } finally {
    await async.closeStatement(insertStmt);
  }
}

Future<void> _runExecuteAsync(
  AsyncNativeOdbcConnection async,
  int connId,
) async {
  AppLogger.info('--- executeAsync demo ---');

  const sql =
      'SELECT id, name, value FROM execute_async_demo_table ORDER BY id';
  final raw = await async.executeAsync(connId, sql);

  if (raw == null) {
    AppLogger.warning('executeAsync failed: ${await async.getError()}');
    return;
  }

  final parsed = BinaryProtocolParser.parse(raw);
  AppLogger.info('executeAsync OK: rowCount=${parsed.rowCount}');
  for (final row in parsed.rows) {
    AppLogger.fine('Row: $row');
  }

  final scalarRaw =
      await async.executeAsync(connId, 'SELECT 1 AS one, GETDATE() AS now');
  if (scalarRaw != null) {
    final scalar = BinaryProtocolParser.parse(scalarRaw);
    AppLogger.info('Scalar query OK: $scalar');
  }
}

Future<void> _runStreamAsync(
  AsyncNativeOdbcConnection async,
  int connId,
) async {
  AppLogger.info('--- streamAsync demo ---');

  const sql =
      'SELECT id, name, value FROM execute_async_demo_table ORDER BY id';
  var totalRows = 0;
  var batchCount = 0;

  await for (final batch in async.streamAsync(
    connId,
    sql,
    fetchSize: 2,
    chunkSize: 4096,
  )) {
    batchCount++;
    totalRows += batch.rowCount;
    for (final row in batch.rows) {
      AppLogger.fine('Stream batch $batchCount row: $row');
    }
  }

  AppLogger.info('streamAsync OK: batches=$batchCount totalRows=$totalRows');
}

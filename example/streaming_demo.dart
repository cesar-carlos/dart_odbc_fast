// Streaming demo with streamQueryBatched and streamQuery.
// Run: dart run example/streaming_demo.dart

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

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

  final connId = native.connect(dsn);
  if (connId == 0) {
    AppLogger.severe('Connection failed: ${native.getError()}');
    return;
  }

  try {
    await _createStreamingTestTable(native, connId, rows: 2000);
    await _runBatchedStreaming(native, connId);
    await _runCustomChunkStreaming(native, connId);
  } finally {
    native.disconnect(connId);
    AppLogger.info('Disconnected');
  }
}

Future<void> _createStreamingTestTable(
  NativeOdbcConnection native,
  int connId, {
  required int rows,
}) async {
  const ddl = '''
    IF OBJECT_ID('streaming_test_table', 'U') IS NOT NULL
      DROP TABLE streaming_test_table;

    CREATE TABLE streaming_test_table (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL,
      value DECIMAL(10,2)
    )
  ''';

  final ddlStmt = native.prepare(connId, ddl);
  if (ddlStmt == 0) {
    AppLogger.warning('DDL prepare failed: ${native.getError()}');
    return;
  }

  try {
    final ddlResult =
        native.executePrepared(ddlStmt, const <ParamValue>[], 0, 1000);
    if (ddlResult == null) {
      AppLogger.warning('DDL execution failed: ${native.getError()}');
      return;
    }
  } finally {
    native.closeStatement(ddlStmt);
  }

  const insertSql =
      'INSERT INTO streaming_test_table (name, value) VALUES (?, ?)';
  final insertStmt = native.prepare(connId, insertSql);
  if (insertStmt == 0) {
    AppLogger.warning('Insert prepare failed: ${native.getError()}');
    return;
  }

  try {
    for (var i = 1; i <= rows; i++) {
      final result = native.executePrepared(
        insertStmt,
        [
          ParamValueString('Item_$i'),
          ParamValueDecimal((i * 1.5).toStringAsFixed(2)),
        ],
        0,
        1000,
      );
      if (result == null) {
        AppLogger.warning('Insert failed at row $i: ${native.getError()}');
        return;
      }
    }
  } finally {
    native.closeStatement(insertStmt);
  }

  AppLogger.info('Inserted $rows rows into streaming_test_table');
}

Future<void> _runBatchedStreaming(
  NativeOdbcConnection native,
  int connId,
) async {
  const sql = 'SELECT id, name, value FROM streaming_test_table ORDER BY id';
  final stream = native.streamQueryBatched(
    connId,
    sql,
    fetchSize: 250,
  );

  var chunks = 0;
  var totalRows = 0;
  final sw = Stopwatch()..start();

  await for (final chunk in stream) {
    chunks++;
    totalRows += chunk.rowCount;
  }

  sw.stop();
  AppLogger.info(
    'Batched stream: chunks=$chunks '
    'rows=$totalRows time=${sw.elapsedMilliseconds}ms',
  );
}

Future<void> _runCustomChunkStreaming(
  NativeOdbcConnection native,
  int connId,
) async {
  const sql = 'SELECT id, name, value FROM streaming_test_table ORDER BY id';
  final stream = native.streamQuery(connId, sql, chunkSize: 500);

  var chunks = 0;
  var totalRows = 0;

  await for (final chunk in stream) {
    chunks++;
    totalRows += chunk.rowCount;
  }

  AppLogger.info('Custom stream: chunks=$chunks rows=$totalRows');
}

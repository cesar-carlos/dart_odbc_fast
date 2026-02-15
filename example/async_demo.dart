// Async ODBC operations demo using AsyncNativeOdbcConnection
//
// Prerequisites: Set ODBC_TEST_DSN in environment variable or .env.
// Execute: dart run example/async_demo.dart

import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show BinaryProtocolParser;
import 'package:odbc_fast/odbc_fast.dart';

const _envPath = '.env';

String _exampleEnvPath() =>
    '${Directory.current.path}${Platform.pathSeparator}$_envPath';

String? _getExampleDsn() {
  final path = _exampleEnvPath();
  final file = File(path);
  if (file.existsSync()) {
    final env = DotEnv(includePlatformEnvironment: true)..load([path]);
    final v = env['ODBC_TEST_DSN'];
    if (v != null && v.isNotEmpty) return v;
  }
  return Platform.environment['ODBC_TEST_DSN'] ??
      Platform.environment['ODBC_DSN'];
}

void main() async {
  AppLogger.initialize();

  final dsn = _getExampleDsn();
  final skipDb = dsn == null || dsn.isEmpty;

  if (skipDb) {
    AppLogger.warning(
      'ODBC_TEST_DSN (or ODBC_DSN) not set. '
      'Create .env with ODBC_TEST_DSN=... or set the environment variable. '
      'Skipping DB-dependent examples.',
    );
    return;
  }

  final async = AsyncNativeOdbcConnection(
    requestTimeout: const Duration(seconds: 30),
  );

  AppLogger.info('=== Initializing AsyncNativeOdbcConnection ===');

  final initResult = await async.initialize();
  if (!initResult) {
    AppLogger.severe('ODBC environment initialization failed');
    return;
  }

  AppLogger.info('OK: ODBC environment initialized');

  final connId = await async.connect(dsn);
  if (connId == 0) {
    final error = await async.getError();
    AppLogger.severe('Connection failed: $error');
    return;
  }

  AppLogger.info('OK: Connected: $connId');

  try {
    await _createTestTable(async, connId);
    await _insertData(async, connId);
    await _queryData(async, connId);
    await _beginTransactionDemo(async, connId);
  } finally {
    await async.disconnect(connId);
    AppLogger.info('OK: Disconnected');
    async.dispose();
    AppLogger.info('OK: AsyncNativeOdbcConnection disposed');
  }

  AppLogger.info('All examples completed.');
}

Future<void> _createTestTable(
  AsyncNativeOdbcConnection async,
  int connId,
) async {
  AppLogger.info('=== Creating test table ===');

  const createTableSql = '''
    IF OBJECT_ID('async_test_table', 'U') IS NOT NULL
      DROP TABLE async_test_table;

    CREATE TABLE async_test_table (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL,
      value DECIMAL(10,2),
      created_at DATETIME DEFAULT GETDATE()
    )
  ''';

  final stmt = await async.prepare(connId, createTableSql);

  if (stmt == 0) {
    final error = await async.getError();
    AppLogger.warning('Prepare failed: $error');
    return;
  }

  final result = await async.executePrepared(
    stmt,
    const <ParamValue>[],
    0,
    1000,
  );

  if (result == null) {
    final error = await async.getError();
    AppLogger.warning('Table creation failed: $error');
  } else {
    AppLogger.info('OK: Table created successfully');
  }

  await async.closeStatement(stmt);
}

Future<void> _insertData(
  AsyncNativeOdbcConnection async,
  int connId,
) async {
  AppLogger.info('=== Inserting data ===');

  const insertSql = 'INSERT INTO async_test_table (name, value) VALUES (?, ?)';
  final stmt = await async.prepare(connId, insertSql);

  if (stmt == 0) {
    final error = await async.getError();
    AppLogger.warning('Prepare failed: $error');
    return;
  }

  for (var i = 1; i <= 5; i++) {
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
      final error = await async.getError();
      AppLogger.warning('Failed to insert item $i: $error');
    } else {
      AppLogger.fine('OK: Item $i inserted');
    }
  }

  await async.closeStatement(stmt);
  AppLogger.info('OK: 5 records inserted');
}

Future<void> _queryData(
  AsyncNativeOdbcConnection async,
  int connId,
) async {
  AppLogger.info('=== Querying data ===');

  const selectSql = 'SELECT id, name, value FROM async_test_table';
  final stmt = await async.prepare(connId, selectSql);

  if (stmt == 0) {
    final error = await async.getError();
    AppLogger.warning('Prepare failed: $error');
    return;
  }

  final data = await async.executePrepared(
    stmt,
    const <ParamValue>[],
    0,
    1000,
  );

  if (data == null) {
    final error = await async.getError();
    AppLogger.warning('Query failed: $error');
  } else {
    final result = BinaryProtocolParser.parse(data);
    AppLogger.info('OK: Query completed successfully');
    AppLogger.info('  records found: ${result.rowCount}');

    for (var i = 0; i < result.rows.length; i++) {
      final row = result.rows[i];
      AppLogger.fine('  Row $i: $row');
    }
  }

  await async.closeStatement(stmt);
}

Future<void> _beginTransactionDemo(
  AsyncNativeOdbcConnection async,
  int connId,
) async {
  AppLogger.info('=== Transaction demo ===');

  final txnId = await async.beginTransaction(connId, 0);
  if (txnId == 0) {
    final error = await async.getError();
    AppLogger.warning('Failed to start transaction: $error');
    return;
  }

  AppLogger.info('OK: transaction started: ID=$txnId');

  const insertSql = 'INSERT INTO async_test_table (name, value) VALUES (?, ?)';
  final stmt = await async.prepare(connId, insertSql);

  if (stmt != 0) {
    await async.executePrepared(
      stmt,
      [
        const ParamValueString('Transaction_Item'),
        const ParamValueDecimal('99.99'),
      ],
      0,
      1000,
    );

    await async.closeStatement(stmt);

    AppLogger.info('OK: Data inserted in transaction');

    final commitResult = await async.commitTransaction(txnId);
    if (commitResult) {
      AppLogger.info('OK: transaction committed');
    } else {
      final error = await async.getError();
      AppLogger.warning('Commit failed: $error');
    }
  } else {
    final error = await async.getError();
    AppLogger.warning('Prepare failed: $error');
  }
}

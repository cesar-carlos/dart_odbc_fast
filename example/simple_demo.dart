// Simple demo - basic table creation and data insertion
//
// Prerequisites: Set ODBC_TEST_DSN in environment variable or .env.
// Execute: dart run example/simple_demo.dart

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

  final native = NativeOdbcConnection();

  final initResult = native.initialize();
  if (!initResult) {
    AppLogger.severe('ODBC environment initialization failed');
    return;
  }

  final connId = native.connect(dsn);
  if (connId == 0) {
    AppLogger.severe('Connection failed: ${native.getError()}');
    return;
  }

  AppLogger.info('Connected: $connId');

  // Create test table
  await _createTestTable(native, connId);

  // Prepare insert statement
  AppLogger.info('Preparing insert statement...');
  final stmt = native.prepare(
    connId,
    'INSERT INTO simple_test_table (name) VALUES (?)',
  );

  if (stmt == 0) {
    AppLogger.warning('Prepare failed: ${native.getError()}');
    return;
  }

  // Insert first record
  AppLogger.info('Inserting first record...');
  final result1 = native.executePrepared(
    stmt,
    [const ParamValueString('Alice')],
    0,
    1000,
  );

  if (result1 == null) {
    AppLogger.severe('First insert failed: ${native.getError()}');
  } else {
    AppLogger.info('First record inserted');
  }

  // Insert second record
  AppLogger.info('Inserting second record...');
  final result2 = native.executePrepared(
    stmt,
    [const ParamValueString('Bob')],
    0,
    1000,
  );

  if (result2 == null) {
    AppLogger.severe('Second insert failed: ${native.getError()}');
  } else {
    AppLogger.info('Second record inserted');
  }

  // Insert third record with explicit NULL
  AppLogger.info('Inserting third record (with NULL)...');
  final result3 = native.executePrepared(
    stmt,
    [const ParamValueString('Charlie'), const ParamValueNull()],
    0,
    1000,
  );

  if (result3 == null) {
    AppLogger.severe('Third insert failed: ${native.getError()}');
  } else {
    AppLogger.info('Third record inserted (with NULL)');
  }

  // Verify all records
  await _verifyInsertedData(native, connId, 3);

  // Close statement
  native.closeStatement(stmt);
  AppLogger.info('Statement closed');

  native.disconnect(connId);
  AppLogger.info('Disconnected');
  AppLogger.info('All examples completed.');
}

Future<void> _createTestTable(
  NativeOdbcConnection native,
  int connId,
) async {
  const createTableSql = '''
    IF OBJECT_ID('simple_test_table', 'U') IS NOT NULL
      DROP TABLE simple_test_table;

    CREATE TABLE simple_test_table (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL,
      age INT
      created_at DATETIME DEFAULT GETDATE()
    )
  ''';

  AppLogger.fine('Creating test table');

  final stmt = native.prepare(connId, createTableSql);

  if (stmt == 0) {
    AppLogger.warning('Prepare failed: ${native.getError()}');
    return;
  }

  final result = native.executePrepared(stmt, const <ParamValue>[], 0, 1000);

  if (result == null) {
    AppLogger.warning('Table creation failed: ${native.getError()}');
    return;
  }

  native.closeStatement(stmt);
  AppLogger.fine('Table created');
}

Future<void> _verifyInsertedData(
  NativeOdbcConnection native,
  int connId,
  int expectedCount,
) async {
  AppLogger.info('Verifying $expectedCount inserted records...');

  const selectSql = 'SELECT id, name, age FROM simple_test_table';
  final stmt = native.prepare(connId, selectSql);

  if (stmt == 0) {
    AppLogger.warning('Prepare failed select: ${native.getError()}');
    native.closeStatement(stmt);
    return;
  }

  final result = native.executePrepared(stmt, const <ParamValue>[], 0, 1000);

  if (result == null) {
    AppLogger.warning('Select failed: ${native.getError()}');
    native.closeStatement(stmt);
    return;
  }

  final selectData =
      native.executePrepared(stmt, const <ParamValue>[], 0, 1000);

  if (selectData == null) {
    AppLogger.warning('Select failed count: ${native.getError()}');
    native.closeStatement(stmt);
    return;
  }

  final selectResult = BinaryProtocolParser.parse(selectData);

  AppLogger.info('records found: ${selectResult.rowCount}');

  if (selectResult.rowCount != expectedCount) {
    AppLogger.warning(
      'Expected $expectedCount records, '
      'found ${selectResult.rowCount}',
    );
  } else {
    AppLogger.info('All $expectedCount records verified');
  }

  native.closeStatement(stmt);
}

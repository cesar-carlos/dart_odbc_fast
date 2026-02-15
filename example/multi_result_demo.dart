// Multi-result demo - queries returning multiple result sets
// of results
//
// Prerequisites: Set ODBC_TEST_DSN in environment variable or .env.
// Execute: dart run example/multi_result_demo.dart

import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart';
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

  // Create test tables and stored procedure
  await _createMultiResultSetup(native, connId);

  // Demonstrate multi-result query with batch
  await _demoMultiResultBatch(native, connId);

  // Demonstrate multi-result parsing
  await _demoMultiResultParser(native, connId);

  native.disconnect(connId);
  AppLogger.info('Disconnected');
  AppLogger.info('All examples completed.');
}

Future<void> _createMultiResultSetup(
  NativeOdbcConnection native,
  int connId,
) async {
  const createTable1Sql = '''
    IF OBJECT_ID('multi_result_users', 'U') IS NOT NULL
      DROP TABLE multi_result_users;

    CREATE TABLE multi_result_users (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL,
      email NVARCHAR(255)
    )
  ''';

  const createTable2Sql = '''
    IF OBJECT_ID('multi_result_orders', 'U') IS NOT NULL
      DROP TABLE multi_result_orders;

    CREATE TABLE multi_result_orders (
      id INT IDENTITY(1,1) PRIMARY KEY,
      user_id INT NOT NULL,
      product NVARCHAR(100) NOT NULL,
      amount DECIMAL(10,2) NOT NULL,
      FOREIGN KEY (user_id) REFERENCES multi_result_users(id)
    )
  ''';

  AppLogger.fine('Creating multi-result test tables');

  for (final sql in [createTable1Sql, createTable2Sql]) {
    final stmt = native.prepare(connId, sql);
    if (stmt == 0) {
      AppLogger.warning('Prepare failed: ${native.getError()}');
      continue;
    }

    native
      ..executePrepared(stmt, const <ParamValue>[], 0, 1000)
      ..closeStatement(stmt);
  }

  AppLogger.fine('Tables created');

  // Insert test data
  AppLogger.info('Inserting test data...');
  const insertUserSql =
      'INSERT INTO multi_result_users (name, email) VALUES (?, ?)';

  for (var i = 1; i <= 3; i++) {
    final stmt = native.prepare(connId, insertUserSql);
    if (stmt != 0) {
      native
        ..executePrepared(
          stmt,
          [
            ParamValueString('User_$i'),
            ParamValueString('user$i@example.com'),
          ],
          0,
          1000,
        )
        ..closeStatement(stmt);
    }
  }

  AppLogger.info('Test data inserted');
}

Future<void> _demoMultiResultBatch(
  NativeOdbcConnection native,
  int connId,
) async {
  AppLogger.info('=== Example: Multi-result batch query ===');

  // SQL Server batch query that returns multiple result sets
  const batchSql = '''
    SELECT * FROM multi_result_users WHERE id <= 2;
    SELECT COUNT(*) as order_count FROM multi_result_orders;
    INSERT INTO multi_result_orders (user_id, product, amount)
      VALUES (1, 'Product A', 100.50);
    SELECT @@ROWCOUNT as affected_rows;
  ''';

  AppLogger.info('Executing multi-result batch query...');

  final result = native.executeQueryMulti(connId, batchSql);
  if (result == null) {
    AppLogger.warning('Multi-result query failed: ${native.getError()}');
    return;
  }

  AppLogger.info('Multi-result payload received: ${result.length} bytes');

  // Parse multi-result
  final items = MultiResultParser.parse(result);
  AppLogger.info('Multi-result items: ${items.length}');

  // Process each item
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item.resultSet != null) {
      AppLogger.info('Item $i: RowCount = ${item.rowCount}');
    } else {
      final resultSet = item.resultSet!;
      AppLogger.info('Item $i: ResultSet');
      AppLogger.info('  Column count: ${resultSet.columnCount}');
      AppLogger.info('  Row count: ${resultSet.rowCount}');
      AppLogger.info('  Columns: ${resultSet.columns}');
    }
  }
}

Future<void> _demoMultiResultParser(
  NativeOdbcConnection native,
  int connId,
) async {
  AppLogger.info('=== Example: Multi-result parser ===');

  // Simple SELECT that returns one result set
  const simpleSql = 'SELECT id, name FROM multi_result_users';

  AppLogger.info('Running simple query...');
  final result = native.executeQueryMulti(connId, simpleSql);
  if (result == null) {
    AppLogger.warning('Query failed: ${native.getError()}');
    return;
  }

  // Parse multi-result
  final items = MultiResultParser.parse(result);
  AppLogger.info('${items.length} items processed');

  // Get first result set (most common use case)
  final firstResultSet = MultiResultParser.getFirstResultSet(items);
  AppLogger.info('First result set:');
  AppLogger.info('  Row count: ${firstResultSet.rowCount}');
  AppLogger.info('  Column count: ${firstResultSet.columnCount}');
  AppLogger.info('  Column names: ${firstResultSet.columnNames}');

  // Display first few rows
  for (var i = 0; i < firstResultSet.rows.length && i < 3; i++) {
    final row = firstResultSet.rows[i];
    AppLogger.fine('  Row $i: $row');
  }

  // Demonstrate accessing all result sets
  AppLogger.info('All result sets:');
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item.resultSet != null) {
      AppLogger.info('  Item $i: Row count ${item.rowCount}');
    }
  }
}

// Named Parameters Demo: demonstrates @name and :name syntax support.
//
// Prerequisites: Set ODBC_TEST_DSN in environment or .env.
// Run: dart run example/named_parameters_demo.dart

import 'dart:io';

import 'package:dotenv/dotenv.dart';
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
      'Create .env with ODBC_TEST_DSN=... or set env var. '
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

  await _createExampleTable(native, connId);
  await runExampleAtSignSyntax(native, connId);
  await runExampleColonSyntax(native, connId);
  await runExamplePreparedStatementNamed(native, connId);

  native.disconnect(connId);
  AppLogger.info('Disconnected');
  AppLogger.info('All examples completed.');
}

Future<void> runExampleAtSignSyntax(
  NativeOdbcConnection native,
  int connId,
) async {
  AppLogger.info('=== Example: Named parameters with @name syntax ===');

  // Use @name syntax for named parameters
  const sql = '''
    INSERT INTO named_params_example (name, age, active)
    VALUES (@name, @age, @active)
  ''';

  final namedParams = <String, Object?>{
    'name': 'Alice',
    'age': 30,
    'active': true,
  };

  AppLogger.info('Executing query with @name syntax');
  AppLogger.info('  SQL: $sql');
  AppLogger.info('  Parameters: $namedParams');

  final stmt = native.prepareStatementNamed(connId, sql);
  if (stmt == null) {
    AppLogger.severe('Prepare failed: ${native.getError()}');
    return;
  }

  final result = stmt.executeNamed(namedParams: namedParams);

  if (result == null) {
    AppLogger.severe('Execute failed: ${native.getError()}');
  } else {
    AppLogger.info('Inserted row successfully');

    // Select and verify
    await _selectAndVerify(native, connId, 'Alice');
  }

  stmt.close();
}

Future<void> runExampleColonSyntax(
  NativeOdbcConnection native,
  int connId,
) async {
  AppLogger.info('=== Example: Named parameters with :name syntax ===');

  // Use :name syntax for named parameters
  const sql = '''
    INSERT INTO named_params_example (name, age, active)
    VALUES (:name, :age, :active)
  ''';

  final namedParams = <String, Object?>{
    'name': 'Bob',
    'age': 25,
    'active': false,
  };

  AppLogger.info('Executing query with :name syntax');
  AppLogger.info('  SQL: $sql');
  AppLogger.info('  Parameters: $namedParams');

  final stmt = native.prepareStatementNamed(connId, sql);
  if (stmt == null) {
    AppLogger.severe('Prepare failed: ${native.getError()}');
    return;
  }

  final result = stmt.executeNamed(namedParams: namedParams);

  if (result == null) {
    AppLogger.severe('Execute failed: ${native.getError()}');
  } else {
    AppLogger.info('Inserted row successfully');

    // Select and verify
    await _selectAndVerify(native, connId, 'Bob');
  }

  stmt.close();
}

Future<void> runExamplePreparedStatementNamed(
  NativeOdbcConnection native,
  int connId,
) async {
  AppLogger.info('=== Example: Prepared statement with named parameters ===');

  // Prepare statement with named parameters
  const sql = '''
    INSERT INTO named_params_example (name, age, active)
    VALUES (@name, @age, @active)
  ''';

  AppLogger.info('Preparing statement');
  AppLogger.info('  SQL: $sql');

  final stmt = native.prepareStatementNamed(connId, sql);
  if (stmt == null) {
    AppLogger.severe('Prepare failed: ${native.getError()}');
    return;
  }

  AppLogger.info('Prepared statement: ${stmt.stmtId}');

  // Execute multiple times with different parameters
  final rows = [
    <String, Object?>{'name': 'Charlie', 'age': 35, 'active': true},
    <String, Object?>{'name': 'Diana', 'age': 28, 'active': true},
    <String, Object?>{'name': 'Eve', 'age': 42, 'active': false},
  ];

  for (var i = 0; i < rows.length; i++) {
    final params = rows[i];
    AppLogger.info(
      'Executing ${i + 1}/${rows.length} with params: $params',
    );

    final result = stmt.executeNamed(namedParams: params);

    if (result == null) {
      AppLogger.severe('Execute failed: ${native.getError()}');
    } else {
      AppLogger.info('Inserted row');
    }
  }

  // Select and verify
  const selectSql = '''
    SELECT name, age, active FROM named_params_example
    WHERE name IN ('Charlie', 'Diana', 'Eve')
  ''';
  await _selectAndVerifyRaw(native, connId, selectSql);

  stmt.close();
}

Future<void> _createExampleTable(
  NativeOdbcConnection native,
  int connId,
) async {
  const createTableSql = '''
    IF OBJECT_ID('named_params_example', 'U') IS NOT NULL
      DROP TABLE named_params_example;

    CREATE TABLE named_params_example (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL,
      age INT NOT NULL,
      active BIT NOT NULL
    )
  ''';

  AppLogger.fine('Creating example table');
  final stmt = native.prepare(connId, createTableSql);
  if (stmt == 0) {
    AppLogger.warning('Prepare failed: ${native.getError()}');
    return;
  }

  final executeResult = native.executePrepared(
    stmt,
    const <ParamValue>[],
    0,
    1000,
  );

  if (executeResult == null) {
    AppLogger.fine('Table created successfully');
  } else {
    AppLogger.warning('Create table failed (may already exist)');
  }

  native.closeStatement(stmt);
}

Future<void> _selectAndVerify(
  NativeOdbcConnection native,
  int connId,
  String name,
) async {
  final selectSql = '''
    SELECT name, age, active FROM named_params_example
    WHERE name = '$name'
  ''';

  final stmt = native.prepare(connId, selectSql);
  if (stmt == 0) {
    AppLogger.severe('Select prepare failed: ${native.getError()}');
    return;
  }

  final result = native.executePrepared(stmt, const <ParamValue>[], 0, 1000);

  if (result != null) {
    AppLogger.info('Selected data:');
    // Parse result from binary protocol (simplified)
    AppLogger.info('  Result bytes: ${result.length} bytes');
  }

  native.closeStatement(stmt);
}

Future<void> _selectAndVerifyRaw(
  NativeOdbcConnection native,
  int connId,
  String sql,
) async {
  final stmt = native.prepare(connId, sql);
  if (stmt == 0) {
    AppLogger.severe('Select prepare failed: ${native.getError()}');
    return;
  }

  final result = native.executePrepared(stmt, const <ParamValue>[], 0, 1000);

  if (result != null) {
    AppLogger.info('Selected data (${result.length} bytes)');
  }

  native.closeStatement(stmt);
}

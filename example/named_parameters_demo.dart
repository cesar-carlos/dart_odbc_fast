// Named parameters demo: @name and :name syntax.
// Run: dart run example/named_parameters_demo.dart

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
    await _createExampleTable(native, connId);
    await _runInsertWithAtSyntax(native, connId);
    await _runInsertWithColonSyntax(native, connId);
    await _runPreparedReuse(native, connId);
    await _printAllRows(native, connId);
  } finally {
    native.disconnect(connId);
    AppLogger.info('Disconnected');
  }
}

Future<void> _runInsertWithAtSyntax(
  NativeOdbcConnection native,
  int connId,
) async {
  const sql = '''
    INSERT INTO named_params_example (name, age, active)
    VALUES (@name, @age, @active)
  ''';

  final stmt = native.prepareStatementNamed(connId, sql);
  if (stmt == null) {
    AppLogger.severe('Prepare (@) failed: ${native.getError()}');
    return;
  }

  try {
    final result = stmt.executeNamed(
      namedParams: <String, Object?>{
        'name': 'Alice',
        'age': 30,
        'active': true,
      },
    );
    if (result == null) {
      AppLogger.severe('Execute (@) failed: ${native.getError()}');
      return;
    }
    AppLogger.info('Inserted row with @name syntax');
  } finally {
    stmt.close();
  }
}

Future<void> _runInsertWithColonSyntax(
  NativeOdbcConnection native,
  int connId,
) async {
  const sql = '''
    INSERT INTO named_params_example (name, age, active)
    VALUES (:name, :age, :active)
  ''';

  final stmt = native.prepareStatementNamed(connId, sql);
  if (stmt == null) {
    AppLogger.severe('Prepare (:) failed: ${native.getError()}');
    return;
  }

  try {
    final result = stmt.executeNamed(
      namedParams: <String, Object?>{
        'name': 'Bob',
        'age': 25,
        'active': false,
      },
    );
    if (result == null) {
      AppLogger.severe('Execute (:) failed: ${native.getError()}');
      return;
    }
    AppLogger.info('Inserted row with :name syntax');
  } finally {
    stmt.close();
  }
}

Future<void> _runPreparedReuse(NativeOdbcConnection native, int connId) async {
  const sql = '''
    INSERT INTO named_params_example (name, age, active)
    VALUES (@name, @age, @active)
  ''';

  final stmt = native.prepareStatementNamed(connId, sql);
  if (stmt == null) {
    AppLogger.severe('Prepare (reuse) failed: ${native.getError()}');
    return;
  }

  final rows = <Map<String, Object?>>[
    <String, Object?>{'name': 'Charlie', 'age': 35, 'active': true},
    <String, Object?>{'name': 'Diana', 'age': 28, 'active': true},
    <String, Object?>{'name': 'Eve', 'age': 42, 'active': false},
  ];

  try {
    for (final params in rows) {
      final result = stmt.executeNamed(namedParams: params);
      if (result == null) {
        AppLogger.severe('Execute (reuse) failed: ${native.getError()}');
        return;
      }
    }
    AppLogger.info(
      'Inserted ${rows.length} rows with reused prepared statement',
    );
  } finally {
    stmt.close();
  }
}

Future<void> _createExampleTable(
  NativeOdbcConnection native,
  int connId,
) async {
  const sql = '''
    IF OBJECT_ID('named_params_example', 'U') IS NOT NULL
      DROP TABLE named_params_example;

    CREATE TABLE named_params_example (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL,
      age INT NOT NULL,
      active BIT NOT NULL
    )
  ''';

  final stmt = native.prepare(connId, sql);
  if (stmt == 0) {
    AppLogger.severe('Create table prepare failed: ${native.getError()}');
    return;
  }

  try {
    final result = native.executePrepared(stmt, const <ParamValue>[], 0, 1000);
    if (result == null) {
      AppLogger.severe('Create table failed: ${native.getError()}');
      return;
    }
    AppLogger.info('Table ready: named_params_example');
  } finally {
    native.closeStatement(stmt);
  }
}

Future<void> _printAllRows(NativeOdbcConnection native, int connId) async {
  const select = '''
    SELECT name, age, active
    FROM named_params_example
    ORDER BY id
  ''';

  final stmt = native.prepare(connId, select);
  if (stmt == 0) {
    AppLogger.warning('Select prepare failed: ${native.getError()}');
    return;
  }

  try {
    final result = native.executePrepared(stmt, const <ParamValue>[], 0, 1000);
    if (result == null) {
      AppLogger.warning('Select failed: ${native.getError()}');
      return;
    }

    final parsed = BinaryProtocolParser.parse(result);
    AppLogger.info('Final rows: ${parsed.rowCount}');
    for (final row in parsed.rows) {
      AppLogger.fine('Row: $row');
    }
  } finally {
    native.closeStatement(stmt);
  }
}

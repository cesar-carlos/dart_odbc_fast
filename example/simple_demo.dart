// Low-level native API demo using NativeOdbcConnection.
// Run: dart run example/simple_demo.dart

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

  AppLogger.info('Connected: $connId');

  try {
    await _createTestTable(native, connId);

    const insertSql = 'INSERT INTO simple_test_table (name, age) VALUES (?, ?)';
    final stmt = native.prepare(connId, insertSql);
    if (stmt == 0) {
      AppLogger.severe('Prepare failed: ${native.getError()}');
      return;
    }

    try {
      final inserts = <List<ParamValue>>[
        [const ParamValueString('Alice'), const ParamValueInt32(30)],
        [const ParamValueString('Bob'), const ParamValueInt32(25)],
        [const ParamValueString('Charlie'), const ParamValueNull()],
      ];

      for (var i = 0; i < inserts.length; i++) {
        final result = native.executePrepared(stmt, inserts[i], 0, 1000);
        if (result == null) {
          AppLogger.severe('Insert ${i + 1} failed: ${native.getError()}');
          return;
        }
      }

      AppLogger.info('Inserted ${inserts.length} rows');
    } finally {
      native.closeStatement(stmt);
    }

    await _verifyInsertedData(native, connId, 3);
  } finally {
    native.disconnect(connId);
    AppLogger.info('Disconnected');
  }
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
      age INT,
      created_at DATETIME DEFAULT GETDATE()
    )
  ''';

  final stmt = native.prepare(connId, createTableSql);
  if (stmt == 0) {
    AppLogger.warning('Prepare failed: ${native.getError()}');
    return;
  }

  try {
    final result = native.executePrepared(stmt, const <ParamValue>[], 0, 1000);
    if (result == null) {
      AppLogger.warning('Table creation failed: ${native.getError()}');
      return;
    }
    AppLogger.info('Table ready: simple_test_table');
  } finally {
    native.closeStatement(stmt);
  }
}

Future<void> _verifyInsertedData(
  NativeOdbcConnection native,
  int connId,
  int expectedCount,
) async {
  const selectSql = 'SELECT id, name, age FROM simple_test_table ORDER BY id';
  final stmt = native.prepare(connId, selectSql);
  if (stmt == 0) {
    AppLogger.warning('Select prepare failed: ${native.getError()}');
    return;
  }

  try {
    final raw = native.executePrepared(stmt, const <ParamValue>[], 0, 1000);
    if (raw == null) {
      AppLogger.warning('Select failed: ${native.getError()}');
      return;
    }

    final parsed = BinaryProtocolParser.parse(raw);
    AppLogger.info('Rows found: ${parsed.rowCount}');

    if (parsed.rowCount != expectedCount) {
      AppLogger.warning(
        'Expected $expectedCount rows, found ${parsed.rowCount}',
      );
    }

    for (final row in parsed.rows) {
      AppLogger.fine('Row: $row');
    }
  } finally {
    native.closeStatement(stmt);
  }
}

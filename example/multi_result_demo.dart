// Multi-result demo using executeQueryMulti, executeQueryMultiParams,
// and MultiResultParser.
// Run: dart run example/multi_result_demo.dart

import 'package:odbc_fast/odbc_fast.dart';
import 'package:odbc_fast/odbc_fast_native.dart';

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
    await _createSetup(native, connId);
    await _runMultiResultBatch(native, connId);
    await _runParameterizedMultiResultBatch(native, connId);
  } finally {
    native.disconnect(connId);
    AppLogger.info('Disconnected');
  }
}

Future<void> _createSetup(NativeOdbcConnection native, int connId) async {
  const ddl = '''
    IF OBJECT_ID('multi_result_users', 'U') IS NOT NULL DROP TABLE multi_result_users;
    IF OBJECT_ID('multi_result_orders', 'U') IS NOT NULL DROP TABLE multi_result_orders;

    CREATE TABLE multi_result_users (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL
    );

    CREATE TABLE multi_result_orders (
      id INT IDENTITY(1,1) PRIMARY KEY,
      user_id INT NOT NULL,
      product NVARCHAR(100) NOT NULL,
      amount DECIMAL(10,2) NOT NULL
    );

    INSERT INTO multi_result_users (name) VALUES ('Alice'), ('Bob');
    INSERT INTO multi_result_orders (user_id, product, amount)
    VALUES (1, 'Book', 10.00), (2, 'Pen', 5.00);
  ''';

  final stmt = native.prepare(connId, ddl);
  if (stmt == 0) {
    AppLogger.severe('Setup prepare failed: ${native.getError()}');
    return;
  }

  try {
    final result = native.executePrepared(stmt, const <ParamValue>[], 0, 1000);
    if (result == null) {
      AppLogger.severe('Setup execution failed: ${native.getError()}');
      return;
    }
    AppLogger.info('Setup ready for multi-result demo');
  } finally {
    native.closeStatement(stmt);
  }
}

Future<void> _runMultiResultBatch(
  NativeOdbcConnection native,
  int connId,
) async {
  const sql = '''
    SELECT id, name FROM multi_result_users ORDER BY id;
    SELECT COUNT(*) AS orders_count FROM multi_result_orders;
    UPDATE multi_result_orders SET amount = amount + 1 WHERE user_id = 1;
    SELECT @@ROWCOUNT AS updated_rows;
  ''';

  final payload = native.executeQueryMulti(connId, sql);
  if (payload == null) {
    AppLogger.severe('Multi-result query failed: ${native.getError()}');
    return;
  }

  final items = MultiResultParser.parse(payload);
  _logMultiResultItems(
    'Multi-result items (plain batch)',
    items,
  );

  final first = MultiResultParser.getFirstResultSet(items);
  if (first != null) {
    AppLogger.info('First result-set rowCount: ${first.rowCount}');
  } else {
    AppLogger.info(
      'No result set in batch (only row-counts) -- expected when the '
      'batch contains DML/DDL only.',
    );
  }
}

Future<void> _runParameterizedMultiResultBatch(
  NativeOdbcConnection native,
  int connId,
) async {
  if (!native.supportsExecuteQueryMultiParams) {
    AppLogger.warning(
      'Loaded native library does not support executeQueryMultiParams. '
      'Skipping parameterized multi-result demo.',
    );
    return;
  }

  const sql = '''
    SELECT ? AS first_a, ? AS first_b, ? AS first_optional;
    SELECT ? AS second_d, ? AS second_e, ? AS second_f;
  ''';

  final payload = native.executeQueryMultiParams(
    connId,
    sql,
    serializeParams(const <ParamValue>[
      ParamValueInt32(1),
      ParamValueInt32(2),
      ParamValueNull(),
      ParamValueInt32(4),
      ParamValueInt32(5),
      ParamValueInt32(6),
    ]),
  );
  if (payload == null) {
    AppLogger.severe(
      'Parameterized multi-result query failed: ${native.getError()}',
    );
    return;
  }

  final items = MultiResultParser.parse(payload);
  _logMultiResultItems(
    'Multi-result items (parameterized batch with >5 params)',
    items,
  );
}

void _logMultiResultItems(String label, List<MultiResultItem> items) {
  AppLogger.info('$label: ${items.length}');

  for (var i = 0; i < items.length; i++) {
    final item = items[i];

    if (item.resultSet != null) {
      final rs = item.resultSet!;
      AppLogger.info(
        'Item $i => result-set '
        '(rows=${rs.rowCount}, columns=${rs.columnCount})',
      );
      for (final row in rs.rows) {
        AppLogger.fine('  Row: $row');
      }
      continue;
    }

    AppLogger.info('Item $i => row-count (${item.rowCount})');
  }
}

// Connection pool demo.
// Run: dart run example/pool_demo.dart

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

  final pool = native.createConnectionPool(dsn, 5);
  if (pool == null) {
    AppLogger.severe('Pool creation failed: ${native.getError()}');
    return;
  }

  AppLogger.info('Pool created: ${pool.poolId}');

  try {
    await _createPoolTestTable(native, pool);
    _demoParallelBulkInsert(pool);
    await _demoConnectionReuse(native, pool);
    _demoHealthCheck(pool);
    _demoPoolState(pool);
    await _demoConcurrentConnections(pool);
  } finally {
    pool.close();
    AppLogger.info('Pool closed');
  }
}

void _demoParallelBulkInsert(ConnectionPool pool) {
  final payload = BulkInsertBuilder()
      .table('pool_test_table')
      .addColumn('name', BulkColumnType.text, maxLen: 100)
      .addRow(['parallel-a']).addRow(['parallel-b']).build();

  final inserted = pool.bulkInsertParallel(
    'pool_test_table',
    const ['name'],
    payload,
  );

  if (inserted < 0) {
    AppLogger.warning('Parallel bulk insert failed');
    return;
  }
  AppLogger.info('Parallel bulk insert rows: $inserted');
}

Future<void> _createPoolTestTable(
  NativeOdbcConnection native,
  ConnectionPool pool,
) async {
  const createTableSql = '''
    IF OBJECT_ID('pool_test_table', 'U') IS NOT NULL
      DROP TABLE pool_test_table;

    CREATE TABLE pool_test_table (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL
    )
  ''';

  final connId = pool.getConnection();
  if (connId == 0) {
    AppLogger.warning('Failed to get pooled connection: ${native.getError()}');
    return;
  }

  try {
    final stmt = native.prepare(connId, createTableSql);
    if (stmt == 0) {
      AppLogger.warning('Prepare failed: ${native.getError()}');
      return;
    }

    try {
      final result =
          native.executePrepared(stmt, const <ParamValue>[], 0, 1000);
      if (result == null) {
        AppLogger.warning('Table creation failed: ${native.getError()}');
        return;
      }
      AppLogger.info('Table ready: pool_test_table');
    } finally {
      native.closeStatement(stmt);
    }
  } finally {
    pool.releaseConnection(connId);
  }
}

Future<void> _demoConnectionReuse(
  NativeOdbcConnection native,
  ConnectionPool pool,
) async {
  const insertSql = 'INSERT INTO pool_test_table (name) VALUES (?)';

  final conn1 = pool.getConnection();
  if (conn1 == 0) {
    AppLogger.warning('Failed to acquire first connection');
    return;
  }

  try {
    final stmt = native.prepare(conn1, insertSql);
    if (stmt == 0) {
      AppLogger.warning('Prepare failed: ${native.getError()}');
      return;
    }
    try {
      native.executePrepared(
        stmt,
        [const ParamValueString('first from pool')],
        0,
        1000,
      );
    } finally {
      native.closeStatement(stmt);
    }
  } finally {
    pool.releaseConnection(conn1);
  }

  final conn2 = pool.getConnection();
  if (conn2 == 0) {
    AppLogger.warning('Failed to acquire second connection');
    return;
  }

  try {
    AppLogger.info('Connection reuse check: first=$conn1 second=$conn2');
  } finally {
    pool.releaseConnection(conn2);
  }
}

void _demoHealthCheck(ConnectionPool pool) {
  final healthy = pool.healthCheck();
  AppLogger.info('Pool health: ${healthy ? 'healthy' : 'unhealthy'}');
}

void _demoPoolState(ConnectionPool pool) {
  final state = pool.getState();
  if (state == null) {
    AppLogger.warning('Unable to read pool state');
    return;
  }

  final active = state.size - state.idle;
  AppLogger.info(
    'Pool state: size=${state.size}, idle=${state.idle}, active=$active',
  );
}

Future<void> _demoConcurrentConnections(ConnectionPool pool) async {
  final acquired = <int>[];

  for (var i = 0; i < 3; i++) {
    final connId = pool.getConnection();
    if (connId == 0) {
      AppLogger.warning('Failed to get connection #$i');
      continue;
    }
    acquired.add(connId);
  }

  AppLogger.info('Acquired ${acquired.length} connections concurrently');

  acquired.forEach(pool.releaseConnection);

  final state = pool.getState();
  if (state != null) {
    AppLogger.info('After release: size=${state.size}, idle=${state.idle}');
  }
}

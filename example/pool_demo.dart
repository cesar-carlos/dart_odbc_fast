// Connection pool demo with metrics
//
// Prerequisites: Set ODBC_TEST_DSN in environment variable or .env.
// Execute: dart run example/pool_demo.dart

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

  AppLogger.info('=== Connection Pool Demo ===');

  // Create connection pool
  AppLogger.info('Creating connection pool with max size 5...');
  final poolId = native.poolCreate(dsn, 5);

  if (poolId == 0) {
    AppLogger.severe('Pool creation failed: ${native.getError()}');
    return;
  }

  AppLogger.info('Pool created: $poolId');

  // Create ConnectionPool wrapper (for convenience methods)
  final pool = native.createConnectionPool(dsn, 5);
  if (pool == null) {
    AppLogger.severe('Failed to create ConnectionPool wrapper');
    native.poolClose(poolId);
    return;
  }

  // Create test table
  await _createPoolTestTable(native, poolId);

  // Demonstrate getting and releasing connections
  await _demoConnectionReuse(native, poolId);

  // Check pool health
  await _demoHealthCheck(pool);

  // Get pool state
  await _demoPoolState(pool);

  // Demonstrate concurrent connections
  await _demoConcurrentConnections(native, poolId);

  // Close pool
  pool.close();
  AppLogger.info('Pool closed');
  AppLogger.info('All examples completed.');
}

Future<void> _createPoolTestTable(
  NativeOdbcConnection native,
  int poolId,
) async {
  const createTableSql = '''
    IF OBJECT_ID('pool_test_table', 'U') IS NOT NULL
      DROP TABLE pool_test_table;

    CREATE TABLE pool_test_table (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL,
      created_at DATETIME DEFAULT GETDATE()
    )
  ''';

  AppLogger.fine('Creating pool test table');

  // Get connection from pool
  final connId = native.poolGetConnection(poolId);
  if (connId == 0) {
    AppLogger.warning('Failed to get connection: ${native.getError()}');
    return;
  }

  final stmt = native.prepare(connId, createTableSql);
  if (stmt == 0) {
    AppLogger.warning('Prepare failed: ${native.getError()}');
    native.poolReleaseConnection(connId);
    return;
  }

  final result = native.executePrepared(stmt, const <ParamValue>[], 0, 1000);
  if (result == null) {
    AppLogger.warning('Table creation failed: ${native.getError()}');
  } else {
    AppLogger.fine('Table created');
  }

  native
    ..closeStatement(stmt)
    ..poolReleaseConnection(connId);

  AppLogger.fine('Connection released back to pool');
}

Future<void> _demoConnectionReuse(
  NativeOdbcConnection native,
  int poolId,
) async {
  AppLogger.info('=== Example: Connection reuse ===');

  // Get connection and perform operations
  AppLogger.info('Getting connection from pool...');
  final connId1 = native.poolGetConnection(poolId);
  if (connId1 == 0) {
    AppLogger.warning('Failed to get connection');
    return;
  }
  AppLogger.info('Connection 1 acquired: $connId1');

  // Perform query
  const insertSql = 'INSERT INTO pool_test_table (name) VALUES (?)';
  final stmt1 = native.prepare(connId1, insertSql);

  if (stmt1 != 0) {
    final result = native.executePrepared(
      stmt1,
      [const ParamValueString('test record 1')],
      0,
      1000,
    );
    if (result != null) {
      AppLogger.info('Record inserted with connection 1');
    }
    native.closeStatement(stmt1);
  }

  // Release connection
  native.poolReleaseConnection(connId1);
  AppLogger.info('Connection 1 released');

  // Get another connection - should reuse the same connection
  AppLogger.info('Getting another connection from pool...');
  final connId2 = native.poolGetConnection(poolId);
  if (connId2 == 0) {
    AppLogger.warning('Failed to get connection');
    return;
  }
  AppLogger.info(
    'Connection 2 acquired: $connId2 (should reuse connection 1)',
  );

  // Perform another query
  final stmt2 = native.prepare(connId2, insertSql);

  if (stmt2 != 0) {
    final result = native.executePrepared(
      stmt2,
      [const ParamValueString('test record 2')],
      0,
      1000,
    );
    if (result != null) {
      AppLogger.info('Record inserted with connection 2');
    }
    native.closeStatement(stmt2);
  }

  native.poolReleaseConnection(connId2);
  AppLogger.info('Connection 2 released');
}

Future<void> _demoHealthCheck(ConnectionPool pool) async {
  AppLogger.info('=== Example: Pool health check ===');

  AppLogger.info('Running health check...');
  final isHealthy = pool.healthCheck();

  if (isHealthy) {
    AppLogger.info('Pool is healthy');
  } else {
    AppLogger.warning('Pool health check failed');
  }
}

Future<void> _demoPoolState(ConnectionPool pool) async {
  AppLogger.info('=== Example: Pool state ===');

  AppLogger.info('Getting pool state...');
  final state = pool.getState();

  if (state == null) {
    AppLogger.warning('Failed to get pool state');
    return;
  }

  AppLogger.info('Pool state:');
  AppLogger.info('  Pool size: ${state.size}');
  AppLogger.info('  Idle connections: ${state.idle}');
  AppLogger.info('  Active connections: ${state.size - state.idle}');
}

Future<void> _demoConcurrentConnections(
  NativeOdbcConnection native,
  int poolId,
) async {
  AppLogger.info('=== Example: Concurrent connections ===');

  // Simulate concurrent operations
  final connections = <int>[];
  for (var i = 0; i < 3; i++) {
    final connId = native.poolGetConnection(poolId);
    if (connId == 0) {
      AppLogger.warning('Failed to get connection $i');
      continue;
    }
    connections.add(connId);
    AppLogger.info('Connection $i acquired: $connId');
  }

  // Release all connections
  for (final connId in connections) {
    native.poolReleaseConnection(connId);
    AppLogger.info('Connection released: $connId');
  }

  // Check final state
  final pool = native.createConnectionPool('', 0);
  if (pool != null) {
    final state = pool.getState();
    if (state != null) {
      AppLogger.info('Final pool state:');
      AppLogger.info('  Pool size: ${state.size}');
      AppLogger.info('  Idle connections: ${state.idle}');
    }
  }
}

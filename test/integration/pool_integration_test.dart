// Connection pool integration test
//
// Tests connection pooling with a real database
//
// Prerequisites: Set ODBC_TEST_DSN in environment variable or .env.
// Execute: dart test test/integration/pool_integration_test.dart

import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Connection pool integration tests', () {
    late NativeOdbcConnection native;
    var poolId = 0;

    setUpAll(() async {
      final dsn = getTestEnv('ODBC_TEST_DSN') ?? getTestEnv('ODBC_DSN');
      if (dsn == null || dsn.isEmpty) {
        print('Skipping integration tests: ODBC_TEST_DSN not set');
        return;
      }

      native = NativeOdbcConnection();
      final initResult = native.initialize();
      if (!initResult) {
        throw Exception('ODBC environment initialization failed');
      }

      // Create connection pool
      poolId = native.poolCreate(dsn, 3);
      if (poolId == 0) {
        throw Exception('Pool creation failed: ${native.getError()}');
      }

      // Create test table
      const createTableSql = '''
        IF OBJECT_ID('pool_test', 'U') IS NOT NULL
          DROP TABLE pool_test;

        CREATE TABLE pool_test (
          id INT IDENTITY(1,1) PRIMARY KEY,
          name NVARCHAR(100) NOT NULL
        )
      ''';

      final connId = native.poolGetConnection(poolId);
      if (connId == 0) {
        throw Exception('Failed to get connection: ${native.getError()}');
      }

      final createStmt = native.prepare(connId, createTableSql);
      if (createStmt == 0) {
        throw Exception('Prepare create failed: ${native.getError()}');
      }

      final createResult =
          native.executePrepared(createStmt, const <ParamValue>[], 0, 1000);
      if (createResult == null) {
        throw Exception('Table creation failed: ${native.getError()}');
      }

      native
        ..closeStatement(createStmt)
        ..poolReleaseConnection(connId);
    });

    tearDownAll(() {
      if (poolId != 0) {
        native.poolClose(poolId);
      }
    });

    test('poolGetConnection returns valid connection ID', () {
      final connId = native.poolGetConnection(poolId);
      expect(connId, greaterThan(0));
      final released = native.poolReleaseConnection(connId);
      expect(released, isTrue);
    });

    test('poolReleaseConnection succeeds for valid connection', () {
      final connId = native.poolGetConnection(poolId);
      if (connId == 0) {
        fail('Failed to get connection');
      }

      final result = native.poolReleaseConnection(connId);
      expect(result, isTrue);
    });

    test('healthCheck returns true for healthy pool', () {
      final isHealthy = native.poolHealthCheck(poolId);
      expect(isHealthy, isTrue);
    });

    test('poolGetState returns valid pool state', () {
      final state = native.poolGetState(poolId);
      expect(state, isNotNull);
      expect(state!.size, equals(3));
      expect(state.idle, greaterThanOrEqualTo(0));
      expect(state.size, greaterThanOrEqualTo(state.idle));
    });

    test('Connection reuse works correctly', () async {
      // Get connection 1
      final connId1 = native.poolGetConnection(poolId);
      if (connId1 == 0) {
        fail('Failed to get connection 1');
      }

      // Use connection 1
      const insertSql = 'INSERT INTO pool_test (name) VALUES (?)';
      final stmt1 = native.prepare(connId1, insertSql);
      if (stmt1 != 0) {
        final result = native.executePrepared(
          stmt1,
          [const ParamValueString('Record1')],
          0,
          1000,
        );
        expect(result, isNotNull);
        native.closeStatement(stmt1);
      }

      // Release connection 1
      native.poolReleaseConnection(connId1);

      // Get connection 2 - should reuse connection 1
      final connId2 = native.poolGetConnection(poolId);
      if (connId2 == 0) {
        fail('Failed to get connection 2');
      }

      // Verify it's the same connection
      expect(connId2, equals(connId1));

      // Use connection 2
      final stmt2 = native.prepare(connId2, insertSql);
      if (stmt2 != 0) {
        final result = native.executePrepared(
          stmt2,
          [const ParamValueString('Record2')],
          0,
          1000,
        );
        expect(result, isNotNull);
        native.closeStatement(stmt2);
      }

      // Release connection 2
      native.poolReleaseConnection(connId2);
    });

    test('poolGetState shows correct idle count after operations', () async {
      final connId = native.poolGetConnection(poolId);
      if (connId == 0) {
        fail('Failed to get connection');
      }

      // Perform operation
      const insertSql = 'INSERT INTO pool_test (name) VALUES (?)';
      final stmt = native.prepare(connId, insertSql);
      if (stmt != 0) {
        native
          ..executePrepared(
            stmt,
            [const ParamValueString('TestRecord')],
            0,
            1000,
          )
          ..closeStatement(stmt);
      }

      // Release connection
      native.poolReleaseConnection(connId);

      // Check state - connection should be idle
      final state = native.poolGetState(poolId);
      expect(state, isNotNull);
      expect(state!.idle, equals(3));
    });

    test('poolClose releases all connections', () async {
      final dsn = getTestEnv('ODBC_TEST_DSN') ?? getTestEnv('ODBC_DSN');
      if (dsn == null || dsn.isEmpty) {
        return;
      }
      final poolId = native.poolCreate(dsn, 2);
      if (poolId == 0) {
        fail('Failed to create pool');
      }

      // Get connections
      final connId1 = native.poolGetConnection(poolId);
      final connId2 = native.poolGetConnection(poolId);
      if (connId1 == 0 || connId2 == 0) {
        fail('Failed to get connections');
      }

      // Close pool
      final closeResult = native.poolClose(poolId);
      expect(closeResult, isTrue);

      // Verify pool is closed
      final state = native.poolGetState(poolId);
      expect(state, isNull);
    });
  });
}

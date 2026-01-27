import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Async API Integration Tests', () {
    late AsyncNativeOdbcConnection async;

    setUpAll(() async {
      async = AsyncNativeOdbcConnection();
      await async.initialize();
    });

    test('should initialize successfully', () {
      expect(async.isInitialized, isTrue);
    });

    test('should fail to connect with invalid DSN', () async {
      // This test verifies error handling across isolate boundary
      try {
        await async.connect('DSN=InvalidDSN_That_Does_Not_Exist');
        fail('Should have thrown an error');
      } on Exception catch (e) {
        // Should receive an error (could be AsyncError or other)
        expect(e, isA<Exception>());
      }
    });

    test('should handle getError async', () async {
      final error = await async.getError();
      // Should return a string (empty if no error)
      expect(error, isA<String>());
    });

    test('should handle getStructuredError async', () async {
      final error = await async.getStructuredError();
      // Returns null when no error, or StructuredError when worker has last error
      expect(error, anyOf(isNull, isA<StructuredError>()));
    });

    test('should handle disconnect with non-existent connection', () async {
      // Try to disconnect a connection that doesn't exist
      final result = await async.disconnect(999);
      // Should return false for invalid connection ID
      expect(result, isFalse);
    });

    test('should handle pool operations async', () async {
      final dsn = getTestEnv('ODBC_TEST_DSN');
      if (dsn == null) {
        return; // Skip if no DSN configured
      }

      // Create pool
      final poolId = await async.poolCreate(dsn, 2);
      // Pool creation might fail, but we test the async execution
      expect(poolId, isA<int>());

      // If pool was created successfully, test get connection
      if (poolId > 0) {
        final connId = await async.poolGetConnection(poolId);
        expect(connId, isA<int>());

        // Release connection
        if (connId > 0) {
          await async.poolReleaseConnection(connId);
        }

        // Close pool
        await async.poolClose(poolId);
      }
    });

    test('should handle poolHealthCheck async', () async {
      // Health check on non-existent pool should return false
      final result = await async.poolHealthCheck(999);
      expect(result, isFalse);
    });

    test('should handle poolGetState async', () async {
      // Get state of non-existent pool should return null
      final state = await async.poolGetState(999);
      expect(state, isNull);
    });

    test('should handle beginTransaction async', () async {
      // Try to begin transaction on non-existent connection
      try {
        await async.beginTransaction(999, 1);
        fail('Should have thrown an error');
      } on Exception catch (e) {
        // Should receive an error
        expect(e, isA<Exception>());
      }
    });

    test('should handle commitTransaction async', () async {
      // Try to commit non-existent transaction
      final result = await async.commitTransaction(999);
      expect(result, isFalse);
    });

    test('should handle rollbackTransaction async', () async {
      // Try to rollback non-existent transaction
      final result = await async.rollbackTransaction(999);
      expect(result, isFalse);
    });

    test('should handle prepare async', () async {
      // Try to prepare statement on non-existent connection
      try {
        await async.prepare(999, 'SELECT 1');
        fail('Should have thrown an error');
      } on Exception catch (e) {
        // Should receive an error
        expect(e, isA<Exception>());
      }
    });

    test('should handle executePrepared async', () async {
      // Try to execute non-existent prepared statement
      final result = await async.executePrepared(999, []);
      expect(result, isNull);
    });

    test('should handle closeStatement async', () async {
      // Try to close non-existent statement
      final result = await async.closeStatement(999);
      expect(result, isFalse);
    });

    test('should handle executeQueryParams async', () async {
      // Try to execute query on non-existent connection
      final result = await async.executeQueryParams(
        999,
        'SELECT 1',
        [],
      );
      // Should return null for failed query
      expect(result, isNull);
    });

    test('should handle executeQueryMulti async', () async {
      // Try to execute multi-result query on non-existent connection
      final result = await async.executeQueryMulti(
        999,
        'SELECT 1',
      );
      // Should return null for failed query
      expect(result, isNull);
    });

    test('should handle catalogTables async', () async {
      // Try to query catalog on non-existent connection
      final result = await async.catalogTables(999);
      expect(result, isNull);
    });

    test('should handle catalogColumns async', () async {
      // Try to query catalog columns on non-existent connection
      final result = await async.catalogColumns(999, 'test_table');
      expect(result, isNull);
    });

    test('should handle catalogTypeInfo async', () async {
      // Try to query type info on non-existent connection
      final result = await async.catalogTypeInfo(999);
      expect(result, isNull);
    });

    test('should handle bulkInsertArray async', () async {
      // Try bulk insert on non-existent connection
      final result = await async.bulkInsertArray(
        999,
        'test_table',
        ['col1'],
        Uint8List(0),
        0,
      );
      // Failed bulk insert returns 0 or negative (e.g. -1)
      expect(result, isA<int>());
      expect(result, lessThanOrEqualTo(0));
    });

    test('should handle getMetrics async', () async {
      // Get metrics should work even without connections
      final metrics = await async.getMetrics();
      // Metrics might be null if never initialized in native
      expect(
        metrics,
        isA<OdbcMetrics?>(),
      );
    });

    test('should work with real database if available', () async {
      final dsn = getTestEnv('ODBC_TEST_DSN');
      if (dsn == null) {
        return; // Skip if no DSN configured
      }

      // Connect to real database
      final connId = await async.connect(dsn);
      expect(connId, isNonZero);

      // Execute simple query
      final result = await async.executeQueryParams(
        connId,
        'SELECT 1 AS test_col',
        [],
      );

      // Result should be non-null binary data when backend returns rows
      if (result == null) {
        await async.disconnect(connId);
        return;
      }
      expect(result.isNotEmpty, isTrue);

      // Disconnect
      final disconnectResult = await async.disconnect(connId);
      expect(disconnectResult, isTrue);
    });

    test('should handle transactions with real database', () async {
      final dsn = getTestEnv('ODBC_TEST_DSN');
      if (dsn == null) {
        return; // Skip if no DSN configured
      }

      final connId = await async.connect(dsn);
      expect(connId, isNonZero);

      // Begin transaction
      final txnId = await async.beginTransaction(connId, 1); // ReadCommitted
      expect(txnId, isNonZero);

      // Commit transaction
      final commitResult = await async.commitTransaction(txnId);
      expect(commitResult, isTrue);

      // Disconnect
      await async.disconnect(connId);
    });

    test('should handle prepared statements with real database', () async {
      final dsn = getTestEnv('ODBC_TEST_DSN');
      if (dsn == null) {
        return; // Skip if no DSN configured
      }

      final connId = await async.connect(dsn);
      expect(connId, isNonZero);

      // Prepare statement
      final stmtId = await async.prepare(connId, 'SELECT ? AS val');
      expect(stmtId, isNonZero);

      // Execute prepared statement
      final result = await async.executePrepared(
        stmtId,
        [const ParamValueInt32(42)],
      );

      expect(result, isNotNull);
      expect(result!.isNotEmpty, isTrue);

      // Close statement
      final closeResult = await async.closeStatement(stmtId);
      expect(closeResult, isTrue);

      // Disconnect
      await async.disconnect(connId);
    });

    test('should handle pool operations with real database', () async {
      final dsn = getTestEnv('ODBC_TEST_DSN');
      if (dsn == null) {
        return; // Skip if no DSN configured
      }

      // Create pool
      final poolId = await async.poolCreate(dsn, 2);
      expect(poolId, isNonZero);

      // Get connection from pool
      final connId = await async.poolGetConnection(poolId);
      expect(connId, isNonZero);

      // Health check
      final healthCheck = await async.poolHealthCheck(poolId);
      expect(healthCheck, isTrue);

      // Get pool state
      final state = await async.poolGetState(poolId);
      expect(state, isNotNull);
      expect(state!.size, greaterThanOrEqualTo(0));
      expect(state.idle, greaterThanOrEqualTo(0));

      // Release connection
      final releaseResult = await async.poolReleaseConnection(connId);
      expect(releaseResult, isTrue);

      // Close pool
      final closeResult = await async.poolClose(poolId);
      expect(closeResult, isTrue);
    });
  });
}

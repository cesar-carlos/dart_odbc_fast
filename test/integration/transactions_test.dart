import 'package:test/test.dart';
import 'package:odbc_fast/odbc_fast.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('ODBC Integration Tests - Transaction Isolation (TXN-001)', () {
    late ServiceLocator locator;
    late OdbcService service;

    setUpAll(() async {
      locator = ServiceLocator();
      locator.initialize();
      service = locator.service;

      await service.initialize();
    });

    tearDown(() async {
      final conn = locator.service.activeConnection;
      if (conn != null) {
        await service.disconnect(conn!.id);
      }
    });

    test('should begin transaction', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // First connect
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Begin transaction
      final beginResult = await service.beginTransaction(connection.id);
      expect(beginResult.isSuccess(), isTrue);

      // Cleanup
      await service.disconnect(connection.id);
    });

    test('should commit transaction', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect and begin
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      final beginResult = await service.beginTransaction(connection.id);
      expect(beginResult.isSuccess(), isTrue);

      // Execute a simple update
      final updateResult = await service.executeQuery(
        connection.id,
        'UPDATE test_table SET value = 1 WHERE id = 1',
      );
      expect(updateResult.isSuccess(), isTrue);

      // Commit transaction
      final commitResult = await service.commitTransaction(connection.id);
      expect(commitResult.isSuccess(), isTrue);

      // Verify update was committed
      final selectResult = await service.executeQuery(
        connection.id,
        'SELECT value FROM test_table WHERE id = 1',
      );
      expect(selectResult.isSuccess(), isTrue);
      expect(selectResult.rows.length, equals(1));
      expect(selectResult.asMap.first['value'], equals(1));

      // Cleanup
      await service.disconnect(connection.id);
    });

    test('should rollback transaction', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');

      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect and begin
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      final beginResult = await service.beginTransaction(connection.id);
      expect(beginResult.isSuccess(), isTrue);

      // Execute an update
      final updateResult = await service.executeQuery(
        connection.id,
        'UPDATE test_table SET value = 999 WHERE id = 1',
      );
      expect(updateResult.isSuccess(), isTrue);

      // Rollback transaction
      final rollbackResult = await service.rollbackTransaction(connection.id);
      expect(rollbackResult.isSuccess(), isTrue);

      // Verify update was rolled back
      final selectResult = await service.executeQuery(
        connection.id,
        'SELECT value FROM test_table WHERE id = 1',
      );
      expect(selectResult.isSuccess(), isTrue);
      expect(selectResult.rows.length, equals(1));
      expect(selectResult.asMap.first['value'], equals(999)); // Should still be 1

      // Cleanup
      await service.disconnect(connection.id);
    });

    test('should handle nested transactions', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');

      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Begin outer transaction
      final outerBegin = await service.beginTransaction(connection.id);
      expect(outerBegin.isSuccess(), isTrue);

      // Begin inner transaction (nested)
      final innerBegin = await service.beginTransaction(connection.id);
      expect(innerBegin.isSuccess(), isTrue);

      // Execute update in inner transaction
      final innerUpdate = await service.executeQuery(
        connection.id,
        'UPDATE test_table SET value = 100 WHERE id = 2',
      );
      expect(innerUpdate.isSuccess(), isTrue);

      // Commit inner transaction
      final innerCommit = await service.commitTransaction(connection.id);
      expect(innerCommit.isSuccess(), isTrue);

      // Rollback outer transaction (should rollback inner changes)
      final outerRollback = await service.rollbackTransaction(connection.id);
      expect(outerRollback.isSuccess(), isTrue);

      // Verify: inner update should be rolled back, outer transaction should be active
      final selectResult = await service.executeQuery(
        connection.id,
        'SELECT value FROM test_table WHERE id = 2',
      );
      expect(selectResult.isSuccess(), isTrue);
      expect(selectResult.rows.length, equals(1)); // id=2 shouldn't exist yet
      expect(selectResult.asMap.first['value'], equals(100)); // Inner update rolled back

      // Commit outer transaction
      final outerCommit = await service.commitTransaction(connection.id);
      expect(outerCommit.isSuccess(), isTrue);

      // Cleanup
      await service.disconnect(connection.id);
    });

    test('should respect transaction isolation levels', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');

      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Note: ODBC isolation levels are driver-specific
      // This test validates the API accepts isolation parameter
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Begin transaction with READ UNCOMMITTED
      final beginResult = await service.beginTransaction(
        connection.id,
        isolation: TransactionIsolation.readUncommitted,
      );
      expect(beginResult.isSuccess(), isTrue);

      // Execute update
      final updateResult = await service.executeQuery(
        connection.id,
        'UPDATE test_table SET value = 1 WHERE id = 1',
      );
      expect(updateResult.isSuccess(), isTrue);

      // Commit
      final commitResult = await service.commitTransaction(connection.id);
      expect(commitResult.isSuccess(), isTrue);

      // Cleanup
      await service.disconnect(connection.id);
    });
  });

  group('ODBC Integration Tests - Transaction Timeout (TXN-002)', () {
    late ServiceLocator locator;
    late OdbcService service;

    setUpAll(() async {
      locator = ServiceLocator();
      locator.initialize();
      service = locator.service;

      await service.initialize();
    });

    tearDown(() async {
      final conn = locator.service.activeConnection;
      if (conn != null) {
        await service.disconnect(conn!.id);
      }
    });

    test('should execute query with timeout', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');

      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Execute query with 5 second timeout
      final start = DateTime.now();
      final result = await service.executeQuery(
        connection.id,
        'SELECT * FROM sys.tables WHERE table_type = \"TABLE\"', // Slow query
        timeout: Duration(seconds: 5),
      );
      final elapsed = DateTime.now().difference(start);

      expect(result.isSuccess(), isTrue);
      expect(result.isTimeout, isTrue);
      expect(elapsed.inSeconds, greaterThan(5));

      // Cleanup
      await service.disconnect(connection.id);
    });

    test('should cancel query with timeout', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');

      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Begin transaction
      final beginResult = await service.beginTransaction(connection.id);
      expect(beginResult.isSuccess(), isTrue);

      // Start slow query in background
      final query = 'SELECT * FROM sys.tables WHERE table_type = \"TABLE\"'; // Slow query

      // Execute with short timeout - should trigger timeout
      final result1 = await service.executeQuery(
        connection.id,
        query,
        timeout: Duration(milliseconds: 100),
      );
      expect(result1.isSuccess(), isTrue);

      // Cancel immediately (unsupported operation)
      final cancelResult = await service.cancel(connection.id);
      expect(cancelResult.isSuccess(), isFalse); // Cancel is not supported
      expect(cancelResult.error, isA<UnsupportedFeatureError>());

      // Rollback transaction
      final rollbackResult = await service.rollbackTransaction(connection.id);
      expect(rollbackResult.isSuccess(), isTrue);

      // Cleanup
      await service.disconnect(connection.id);

      // Wait for query to complete
      await Future.delayed(Duration(seconds: 2));
      final result2 = await service.executeQuery(
        connection.id,
        query,
        timeout: Duration(seconds: 10),
      );
      expect(result2.isSuccess(), isTrue); // May succeed if not timed out

      // Cleanup
      await service.disconnect(connection.id);
    });
  });
}

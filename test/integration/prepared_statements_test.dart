import 'package:test/test.dart';
import 'package:odbc_fast/odbc_fast.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('ODBC Integration Tests - Prepared Statements (PREP-001, PREP-002)', () {
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

    test('should prepare statement', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // First connect
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Prepare statement
      final prepareResult = await service.prepareStatement(
        connection.id,
        'SELECT * FROM test_table WHERE id = ?',
      );
      expect(prepareResult.isSuccess(), isTrue);

      // Verify prepared statement is tracked
      final metrics = service.getPreparedStatementsMetrics();
      expect(metrics.totalStatements, equals(1));
      expect(metrics.cacheHits, equals(0)); // First prepare, no cache hit yet

      // Cleanup
      await service.disconnect(connection.id);
    });

    test('should execute prepared statement multiple times', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Prepare statement
      final prepareResult = await service.prepareStatement(
        connection.id,
        'SELECT * FROM test_table WHERE id = ?',
      );
      expect(prepareResult.isSuccess(), isTrue);

      // Execute with different params
      for (int i = 1; i <= 3; i++) {
        final execResult = await service.executePrepared(
          connection.id,
          prepareResult.statementId,
          [i],
        );
        expect(execResult.isSuccess(), isTrue);

        // Verify row count
        expect(execResult.rows.length, equals(1));
      }

      // Check metrics - 3 executions, 1 prepare (cache hit rate should be 66.7%)
      final metrics = service.getPreparedStatementsMetrics();
      expect(metrics.totalExecutions, equals(3));
      expect(metrics.totalStatements, equals(1));
      expect(metrics.cacheHits, greaterThan(0));

      // Cleanup
      await service.disconnect(connection.id);
    });

    test('should close prepared statement', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Prepare statement
      final prepareResult = await service.prepareStatement(
        connection.id,
        'SELECT * FROM test_table WHERE id = ?',
      );
      expect(prepareResult.isSuccess(), isTrue);

      // Close statement
      final closeResult = await service.closeStatement(prepareResult.statementId);
      expect(closeResult.isSuccess(), isTrue);

      // Verify statement is no longer tracked
      final metrics = service.getPreparedStatementsMetrics();
      expect(metrics.totalStatements, equals(0));

      // Cleanup
      await service.disconnect(connection.id);
    });

    test('should clear statement cache', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Prepare multiple statements to populate cache
      final stmt1 = await service.prepareStatement(
        connection.id,
        'SELECT * FROM test_table WHERE id = ?',
      );
      final stmt2 = await service.prepareStatement(
        connection.id,
        'SELECT * FROM test_table WHERE category = ?',
      );
      expect(stmt1.isSuccess(), isTrue);
      expect(stmt2.isSuccess(), isTrue);

      // Verify cache is populated
      final metrics = service.getPreparedStatementsMetrics();
      expect(metrics.totalStatements, equals(2));

      // Clear cache
      final clearResult = await service.clearStatementCache();
      expect(clearResult.isSuccess(), isTrue);

      // Verify cache is cleared
      final metricsAfterClear = service.getPreparedStatementsMetrics();
      expect(metricsAfterClear.totalStatements, equals(0));

      // Cleanup
      await service.disconnect(connection.id);
    });

    test('should get statement options per execution', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Prepare statement with default options
      final prepareResult = await service.prepareStatement(
        connection.id,
        'SELECT * FROM test_table WHERE id = ?',
      );
      expect(prepareResult.isSuccess(), isTrue);

      // Execute with custom timeout (10s)
      final exec1 = await service.executePrepared(
        connection.id,
        prepareResult.statementId,
        [1],
        options: const StatementOptions(timeout: Duration(seconds: 10)),
      );

      // Execute with custom timeout (2s)
      final exec2 = await service.executePrepared(
        connection.id,
        prepareResult.statementId,
        [1],
        options: const StatementOptions(timeout: Duration(seconds: 2)),
      );

      // First should succeed, second should timeout
      expect(exec1.isSuccess(), isTrue);
      expect(exec2.isSuccess(), isFalse);
      expect(exec2.error, isA<TimeoutError>());

      // Cleanup
      await service.disconnect(connection.id);
    });

    test('should handle fetch size option', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Prepare statement
      final prepareResult = await service.prepareStatement(
        connection.id,
        'SELECT * FROM test_table WHERE id = ?',
      );
      expect(prepareResult.isSuccess(), isTrue);

      // Execute with custom fetch size
      final execResult = await service.executePrepared(
        connection.id,
        prepareResult.statementId,
        [1],
        options: const StatementOptions(fetchSize: 100),
      );

      expect(execResult.isSuccess(), isTrue);
      expect(execResult.rows.length, greaterThan(0));

      // Cleanup
      await service.disconnect(connection.id);
    });
  });
}

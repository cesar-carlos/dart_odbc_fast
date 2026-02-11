import 'package:test/test.dart';
import 'package:odbc_fast/odbc_fast.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('ODBC Integration Tests - Prepared Statement Lifecycle (PREP-001)', () {
    late ServiceLocator locator;
    late OdbcService service;

    setUpAll(() async {
      locator = ServiceLocator();
      locator.initialize();
      service = locator.service;

      await service.initialize();
    });

    test('should prepare and execute statement', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Prepare statement
      final stmtResult = await service.prepareStatement(
        connectionString,
        'SELECT * FROM users WHERE department = ?',
      );
      expect(stmtResult.isSuccess(), isTrue);
      final stmt = stmtResult.getOrElse((_) => throw Exception());

      // Execute multiple times
      final result1 = await service.executePrepared(stmt.id, ['Sales']);
      expect(result1.isSuccess(), isTrue);

      final result2 =
          await service.executePrepared(stmt.id, ['Engineering', 'Active']);
      expect(result2.isSuccess(), isTrue);

      // Unprepare to release resources
      await service.unprepareStatement(stmt.id);
      expect(
        await service.unprepareStatement(stmt.id).isSuccess(),
        isFalse,
      ); // Already closed
    });

    test('should execute with StatementOptions', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Prepare statement with timeout option
      final stmtResult = await service.prepareStatement(
        connectionString,
        'SELECT * FROM products WHERE id = ?',
        timeout: const Duration(seconds: 10),
      );
      expect(stmtResult.isSuccess(), isTrue);
      final stmt = stmtResult.getOrElse((_) => throw Exception());

      // Execute with timeout
      final result = await service.executePrepared(
        stmt.id,
        ['product_id'],
        options: const StatementOptions(
          queryTimeout: Duration(seconds: 5),
        ),
      );
      expect(result.isSuccess(), isTrue);
    });

    test('should get metrics', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Execute some statements to generate metrics
      for (var i = 0; i < 3; i++) {
        final stmtResult = await service.prepareStatement(
          connectionString,
          'SELECT * FROM users',
        );
        expect(stmtResult.isSuccess(), isTrue);
        await service.executePrepared(
          stmtResult.getOrElse((_) => throw Exception()).id,
          [],
        );
      }

      // Get metrics - should have 3 statements prepared
      final metrics = await service.getPreparedStatementsMetrics();
      expect(metrics.isSuccess(), isTrue);
      expect(metrics.totalStatements, equals(3));
      expect(metrics.totalExecutions, greaterThanOrEqualTo(3));
      expect(metrics.hitRate, greaterThanOrEqualTo(0.0));
    });
  });
}

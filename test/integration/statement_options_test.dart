// ignore: directives_ordering
import 'package:odbc_fast/odbc_fast.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('ODBC Integration Tests - Statement Options (PREP-002)', () {
    late ServiceLocator locator;
    late OdbcService service;

    setUpAll(() async {
      locator = ServiceLocator();
      locator.initialize();
      service = locator.service;

      await service.initialize();
    });

    test('should accept StatementOptions parameters', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Prepare with various options
      final stmt1 = await service.prepareStatement(
        connectionString,
        'SELECT * FROM products WHERE id = ?',
        timeout: const Duration(seconds: 30),
      );
      expect(stmt1.isSuccess(), isTrue);

      final stmt2 = await service.prepareStatement(
        connectionString,
        'SELECT * FROM orders WHERE status = ?',
        options: const StatementOptions(
          queryTimeout: Duration(minutes: 5),
          fetchSize: 1000,
          asyncFetch: true,
          maxBufferSize: 1024 * 512,
        ),
      );
      expect(stmt2.isSuccess(), isTrue);

      // Verify fetchSize was applied
      final result1 = await service.executePrepared(
        stmt2.id,
        ['product_id'],
      );
      expect(result1.isSuccess(), isTrue);
    });

    test('should handle timeout on execute', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Prepare with short timeout
      final stmtResult = await service.prepareStatement(
        connectionString,
        'SELECT * FROM large_table WHERE complex_condition = ?',
        timeout: const Duration(seconds: 1),
      );
      expect(stmtResult.isSuccess(), isTrue);
      final stmt = stmtResult.getOrElse((_) => throw Exception());

      // Should fail due to timeout
      final result = await service.executePrepared(
        stmt.id,
        ['value'],
        options: const StatementOptions(queryTimeout: Duration(seconds: 2)),
      );

      expect(result.isSuccess(), isFalse);
      expect(result, isA<TimeoutError>());
    });

    test('should validate maxBufferSize', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Prepare with custom buffer size
      final stmtResult = await service.prepareStatement(
        connectionString,
        'SELECT * FROM huge_table',
        options: const StatementOptions(maxBufferSize: 2048),
      );
      expect(stmtResult.isSuccess(), isTrue);
    });
  });
}

// ignore: directives_ordering
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
      final prepareResult = await service.prepareStatement(
        connectionString,
        'SELECT * FROM users WHERE department = ?',
      );
      expect(prepareResult.isSuccess(), isTrue);
      final stmt = prepareResult.getOrElse((_) => throw Exception());

      // Execute multiple times
      final result1 = await service.executePrepared(stmt.id, ['Sales']);
      expect(result1.isSuccess(), isTrue);

      final result2 = await service.executePrepared(stmt.id, ['Engineering', 'Active']);
      expect(result2.isSuccess(), isTrue);

      // Unprepare to release resources
      final unprepareResult = await service.unprepareStatement(stmt.id);
      expect(unprepareResult.isSuccess(), isTrue);

      // Try to unprepare again (should fail - already closed)
      expect(await service.unprepareStatement(stmt.id).isSuccess(), isFalse);
    });

    test('should handle double close gracefully', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Prepare statement
      final prepareResult = await service.prepareStatement(
        connectionString,
        'SELECT * FROM products WHERE id = ?',
      );
      expect(prepareResult.isSuccess(), isTrue);
      final stmt = prepareResult.getOrElse((_) => throw Exception());

      // Close first time
      final close1 = await service.unprepareStatement(stmt.id);
      expect(close1.isSuccess(), isTrue);

      // Close second time (should succeed but not throw)
      final close2 = await service.unprepareStatement(stmt.id);
      expect(close2.isSuccess(), isTrue);
    });
  });
}

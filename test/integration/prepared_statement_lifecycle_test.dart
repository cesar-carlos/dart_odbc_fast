import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';
import '../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('ODBC Integration Tests - Prepared Statement Lifecycle (PREP-001)', () {
    late ServiceLocator locator;
    late OdbcService service;

    setUpAll(() async {
      locator = ServiceLocator();
      // initialize() returns void, so cascade cannot be used in assignment.
      // ignore: cascade_invocations
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

      // First, establish a connection
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final conn = connResult.getOrElse((_) => throw Exception());

      // Prepare statement
      final prepareResult = await service.prepare(
        conn.id,
        'SELECT * FROM users WHERE department = ?',
      );
      expect(prepareResult.isSuccess(), isTrue);
      final stmt = prepareResult.getOrElse((_) => throw Exception());

      // Execute multiple times
      final result1 = await service.executePrepared(
        conn.id,
        stmt,
        ['Sales'],
        null,
      );
      expect(result1.isSuccess(), isTrue);

      final result2 = await service.executePrepared(
        conn.id,
        stmt,
        ['Engineering'],
        null,
      );
      expect(result2.isSuccess(), isTrue);

      // Close statement to release resources
      final unprepareResult = await service.closeStatement(conn.id, stmt);
      expect(unprepareResult.isSuccess(), isTrue);

      // Try to close again (should succeed - idempotent)
      final close2 = await service.closeStatement(conn.id, stmt);
      expect(close2.isSuccess(), isTrue);

      // Clean up connection
      await service.disconnect(conn.id);
    });
  });
}

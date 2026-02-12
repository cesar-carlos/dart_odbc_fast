import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';
import '../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('ODBC Integration Tests - Statement Options (PREP-002)', () {
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

    test('should accept StatementOptions parameters', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // First, establish a connection
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final conn = connResult.getOrElse((_) => throw Exception());

      // Prepare with timeout (timeoutMs is in milliseconds)
      final stmt1Result = await service.prepare(
        conn.id,
        'SELECT * FROM products WHERE id = ?',
        timeoutMs: 30000,
      );
      expect(stmt1Result.isSuccess(), isTrue);
      final stmt1 = stmt1Result.getOrElse((_) => throw Exception());

      // Prepare another statement
      final stmt2Result = await service.prepare(
        conn.id,
        'SELECT * FROM orders WHERE status = ?',
      );
      expect(stmt2Result.isSuccess(), isTrue);
      final stmt2 = stmt2Result.getOrElse((_) => throw Exception());

      // Execute with StatementOptions
      final result1 = await service.executePrepared(
        conn.id,
        stmt2,
        ['pending'],
        const StatementOptions(
          timeout: Duration(minutes: 5),
          fetchSize: 1000,
        ),
      );
      expect(result1.isSuccess(), isTrue);

      // Clean up
      await service.closeStatement(conn.id, stmt1);
      await service.closeStatement(conn.id, stmt2);
      await service.disconnect(conn.id);
    });
  });
}

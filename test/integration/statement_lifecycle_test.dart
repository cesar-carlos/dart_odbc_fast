import 'package:test/test.dart';
import 'package:odbc_fast/odbc_fast.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('ODBC Integration Tests - Statement Lifecycle (PREP-003)', () {
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

    test('should prepare statement with config', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;
      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Prepare with config
      final config = PreparedStatementConfig(
        maxCacheSize: 100,
        ttl: Duration(minutes: 10),
      );

      final prepareResult = await service.prepareStatement(
        connection.id,
        'SELECT * FROM test_table WHERE id = ?',
        config: config,
      );

      expect(prepareResult.isSuccess(), isTrue);
      expect(prepareResult.config?.maxCacheSize, equals(100));
      expect(prepareResult.config?.ttl?.inMinutes, equals(10));
      expect(prepareResult.config?.enabled, isTrue);

      // Verify cache key format
      expect(prepareResult.cacheKey, contains('$connection.id'));
      expect(prepareResult.cacheKey, contains('SELECT * FROM test_table WHERE id = ?'));

      // Cleanup
      await service.disconnect(connection.id);
    });

    test('should unprepare statement', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;
      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Prepare without config (default behavior)
      final prepareResult = await service.prepareStatement(
        connection.id,
        'SELECT * FROM test_table WHERE id = ?',
      );

      expect(prepareResult.isSuccess(), isTrue);
      expect(prepareResult.config, isNull); // No config passed

      // Unprepare
      final unprepareResult = await service.unprepare(
        prepareResult.statementId,
      );

      expect(unprepareResult.isSuccess(), isTrue);

      // Cleanup
      await service.disconnect(connection.id);
    });

    test('should use cache key correctly', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;
      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Prepare
      final prepareResult = await service.prepareStatement(
        connection.id,
        'SELECT * FROM test_table WHERE id = ?',
      );

      expect(prepareResult.isSuccess(), isTrue);

      // Verify cache key format (sql:connectionId)
      expect(prepareResult.cacheKey, equals('SELECT * FROM test_table WHERE id = ?:$connection.id'));

      // Cleanup
      await service.disconnect(connection.id);
    });
  });
}

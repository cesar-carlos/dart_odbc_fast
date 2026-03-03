/// E2E smoke tests with real DLL and ODBC.
///
/// Requires ODBC_TEST_DSN in environment or .env.
/// Skips when not configured.
library;

import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  if (getTestEnv('ODBC_TEST_DSN') == null) {
    return;
  }

  group('ODBC E2E smoke', () {
    ServiceLocator? locator;
    var dsn = '';
    String? skipReason;

    setUpAll(() async {
      dsn = getTestEnv('ODBC_TEST_DSN') ?? '';
      if (dsn.isEmpty) {
        skipReason = 'ODBC_TEST_DSN not configured';
        return;
      }
      try {
        final sl = ServiceLocator()..initialize(useAsync: true);
        await sl.syncService.initialize();
        await sl.asyncService.initialize();
        locator = sl;
      } on Object catch (e) {
        skipReason = 'Native environment unavailable: $e';
      }
    });

    tearDownAll(() {
      locator?.shutdown();
    });

    test(
      'should connect, execute SELECT 1, disconnect (sync)',
      () async {
        if (skipReason != null || dsn.isEmpty || locator == null) return;

        final connResult = await locator!.syncService.connect(dsn);
        final connection =
            connResult.getOrElse((_) => throw Exception('Failed to connect'));

        final queryResult = await locator!.syncService.executeQueryParams(
          connection.id,
          'SELECT 1',
          [],
        );

        expect(queryResult.isSuccess(), isTrue);
        queryResult.fold(
          (result) {
            expect(result.rowCount, greaterThanOrEqualTo(0));
          },
          (_) => fail('Query should succeed'),
        );

        await locator!.syncService.disconnect(connection.id);
      },
    );

    test(
      'should connect, execute SELECT 1, disconnect (async)',
      () async {
        if (skipReason != null || dsn.isEmpty || locator == null) return;

        final connResult = await locator!.asyncService.connect(dsn);
        final connection =
            connResult.getOrElse((_) => throw Exception('Failed to connect'));

        final queryResult = await locator!.asyncService.executeQueryParams(
          connection.id,
          'SELECT 1',
          [],
        );

        expect(queryResult.isSuccess(), isTrue);
        queryResult.fold(
          (result) {
            expect(result.rowCount, greaterThanOrEqualTo(0));
          },
          (_) => fail('Query should succeed'),
        );

        await locator!.asyncService.disconnect(connection.id);
      },
    );

    test('should complete full audit cycle (sync)', () async {
      if (skipReason != null || dsn.isEmpty || locator == null) return;
      if (!locator!.nativeConnection.supportsAuditApi) return;

      final audit = locator!.auditLogger;
      expect(audit.enable(), isTrue);
      expect(audit.clear(), isTrue);

      final connResult = await locator!.syncService.connect(dsn);
      final connection =
          connResult.getOrElse((_) => throw Exception('Failed to connect'));

      final queryResult = await locator!.syncService.executeQueryParams(
        connection.id,
        'SELECT 1',
        [],
      );
      expect(queryResult.isSuccess(), isTrue);

      await locator!.syncService.disconnect(connection.id);

      final status = audit.getStatus();
      expect(status, isNotNull);
      expect(status!.enabled, isTrue);

      final events = audit.getEvents(limit: 100);
      expect(events, isNotEmpty);

      expect(audit.clear(), isTrue);
      final clearedStatus = audit.getStatus();
      expect(clearedStatus, isNotNull);
      expect(clearedStatus!.eventCount, 0);
    });

    test('should complete full audit cycle (async)', () async {
      if (skipReason != null || dsn.isEmpty || locator == null) return;
      if (!locator!.nativeConnection.supportsAuditApi) return;

      final audit = locator!.asyncAuditLogger;
      expect(await audit.enable(), isTrue);
      expect(await audit.clear(), isTrue);

      final connResult = await locator!.asyncService.connect(dsn);
      final connection =
          connResult.getOrElse((_) => throw Exception('Failed to connect'));

      final queryResult = await locator!.asyncService.executeQueryParams(
        connection.id,
        'SELECT 1',
        [],
      );
      expect(queryResult.isSuccess(), isTrue);

      await locator!.asyncService.disconnect(connection.id);

      final status = await audit.getStatus();
      expect(status, isNotNull);
      expect(status!.enabled, isTrue);

      final events = await audit.getEvents(limit: 100);
      expect(events, isNotEmpty);

      expect(await audit.clear(), isTrue);
      final clearedStatus = await audit.getStatus();
      expect(clearedStatus, isNotNull);
      expect(clearedStatus!.eventCount, 0);
    });

    test('should return driver capabilities for DSN', () {
      if (skipReason != null || dsn.isEmpty || locator == null) return;
      if (!locator!.nativeConnection.supportsDriverCapabilitiesApi) return;

      final caps = locator!.nativeConnection.getDriverCapabilities(dsn);

      expect(caps, isNotNull);
      expect(caps!.driverName, isNotEmpty);
      expect(caps.supportsPreparedStatements, isTrue);
    });
  });
}

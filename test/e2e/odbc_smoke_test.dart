/// E2E smoke tests with real DLL and ODBC.
///
/// Requires ENABLE_E2E_TESTS=1, RUN_LIVE_TESTS=1, and ODBC_TEST_DSN.
library;

import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group(
    'ODBC E2E smoke',
    () {
      ServiceLocator? locator;
      var dsn = '';

      setUpAll(() async {
        dsn = getTestEnv('ODBC_TEST_DSN') ?? '';
        try {
          final sl = ServiceLocator()..initialize(useAsync: true);
          await sl.syncService.initialize();
          await sl.asyncService.initialize();
          locator = sl;
        } on Object catch (e, st) {
          markTestSkipped('Native environment unavailable: $e\n$st');
        }
      });

      tearDownAll(() {
        locator?.shutdown();
      });

      test(
        'should connect, execute SELECT 1, disconnect (sync)',
        () async {
          final connResult = await locator!.syncService.connect(dsn);
          final connection =
              connResult.getOrElse((_) => throw Exception('Failed to connect'));

          final queryResult =
              await locator!.syncService.executeQueryParamValuesFromObjects(
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
          final connResult = await locator!.asyncService.connect(dsn);
          final connection =
              connResult.getOrElse((_) => throw Exception('Failed to connect'));

          final queryResult =
              await locator!.asyncService.executeQueryParamValuesFromObjects(
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
        if (!locator!.nativeConnection.supportsAuditApi) {
          markTestSkipped('Audit API not supported by loaded native library');
        }

        final audit = locator!.auditLogger;
        expect(audit.enable(), isTrue);
        expect(audit.clear(), isTrue);

        final connResult = await locator!.syncService.connect(dsn);
        final connection =
            connResult.getOrElse((_) => throw Exception('Failed to connect'));

        final queryResult =
            await locator!.syncService.executeQueryParamValuesFromObjects(
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
        if (!locator!.nativeConnection.supportsAuditApi) {
          markTestSkipped('Audit API not supported by loaded native library');
        }

        final audit = locator!.asyncAuditLogger;
        expect(await audit.enable(), isTrue);
        expect(await audit.clear(), isTrue);

        final connResult = await locator!.asyncService.connect(dsn);
        final connection =
            connResult.getOrElse((_) => throw Exception('Failed to connect'));

        final queryResult =
            await locator!.asyncService.executeQueryParamValuesFromObjects(
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
        if (!locator!.nativeConnection.supportsDriverCapabilitiesApi) {
          markTestSkipped(
            'Driver capabilities API not supported by loaded native library',
          );
        }

        final caps = locator!.nativeConnection.getDriverCapabilities(dsn);

        expect(caps, isNotNull);
        expect(caps!.driverName, isNotEmpty);
        expect(caps.supportsPreparedStatements, isTrue);
      });
    },
    skip: skipUnlessE2eTest(),
  );
}

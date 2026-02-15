// Named parameters integration tests (sync + async service APIs).
//
// Prerequisites:
// - valid native library with ODBC symbols
// - ODBC_TEST_DSN or ODBC_DSN configured
//
// Run:
// dart test test/integration/named_parameters_integration_test.dart

import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Named parameters integration', () {
    ServiceLocator? locator;
    String? skipReason;
    var dsn = '';

    setUpAll(() async {
      dsn = getTestEnv('ODBC_TEST_DSN') ?? getTestEnv('ODBC_DSN') ?? '';
      if (dsn.isEmpty) {
        skipReason = 'ODBC_TEST_DSN/ODBC_DSN not set';
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

    test('sync executeQueryNamed binds @name/:name values', () async {
      if (skipReason != null || locator == null) return;

      final conn = await locator!.syncService.connect(dsn);
      final connection =
          conn.getOrElse((_) => throw Exception('connect failed'));

      final result = await locator!.syncService.executeQueryNamed(
        connection.id,
        'SELECT :value AS value_col',
        {'value': 123},
      );
      expect(result.isSuccess(), isTrue);
      result.fold(
        (success) {
          expect(success.rows, isNotEmpty);
          expect(success.rows.first, isNotEmpty);
          expect(success.rows.first.first.toString(), equals('123'));
        },
        (_) => fail('executeQueryNamed should succeed'),
      );

      await locator!.syncService.disconnect(connection.id);
    });

    test('async executeQueryNamed binds @name/:name values', () async {
      if (skipReason != null || locator == null) return;

      final conn = await locator!.asyncService.connect(dsn);
      final connection =
          conn.getOrElse((_) => throw Exception('connect failed'));

      final result = await locator!.asyncService.executeQueryNamed(
        connection.id,
        'SELECT @value AS value_col',
        {'value': 456},
      );
      expect(result.isSuccess(), isTrue);
      result.fold(
        (success) {
          expect(success.rows, isNotEmpty);
          expect(success.rows.first, isNotEmpty);
          expect(success.rows.first.first.toString(), equals('456'));
        },
        (_) => fail('executeQueryNamed should succeed'),
      );

      await locator!.asyncService.disconnect(connection.id);
    });

    test('async prepareNamed + executePreparedNamed works', () async {
      if (skipReason != null || locator == null) return;

      final conn = await locator!.asyncService.connect(dsn);
      final connection =
          conn.getOrElse((_) => throw Exception('connect failed'));

      final stmtResult = await locator!.asyncService.prepareNamed(
        connection.id,
        'SELECT :v AS value_col',
      );
      final stmtId =
          stmtResult.getOrElse((_) => throw Exception('prepare failed'));

      final result = await locator!.asyncService.executePreparedNamed(
        connection.id,
        stmtId,
        {'v': 789},
        null,
      );
      expect(result.isSuccess(), isTrue);
      result.fold(
        (success) {
          expect(success.rows, isNotEmpty);
          expect(success.rows.first, isNotEmpty);
          expect(success.rows.first.first.toString(), equals('789'));
        },
        (_) => fail('executePreparedNamed should succeed'),
      );

      await locator!.asyncService.closeStatement(connection.id, stmtId);
      await locator!.asyncService.disconnect(connection.id);
    });

    test(
      'sync executeQueryMultiFull returns all result sets',
      skip: skipUnlessDatabase(
        [DatabaseType.sqlServer],
        reason: 'Multi-set SQL validated on SQL Server',
      ),
      () async {
        if (skipReason != null || locator == null) return;

        final conn = await locator!.syncService.connect(dsn);
        final connection =
            conn.getOrElse((_) => throw Exception('connect failed'));

        final result = await locator!.syncService.executeQueryMultiFull(
          connection.id,
          'SELECT 1 AS a; SELECT 2 AS b;',
        );
        expect(result.isSuccess(), isTrue);
        result.fold(
          (success) {
            expect(success.resultSets.length, greaterThanOrEqualTo(2));
            expect(
              success.resultSets.first.rows.first.first.toString(),
              equals('1'),
            );
          },
          (_) => fail('executeQueryMultiFull should succeed'),
        );

        await locator!.syncService.disconnect(connection.id);
      },
    );
  });
}

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

  group(
    'Named parameters integration',
    () {
      late ServiceLocator locator;
      late String dsn;

      setUpAll(() async {
        dsn = getTestEnv('ODBC_TEST_DSN') ?? getTestEnv('ODBC_DSN') ?? '';
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
        locator.shutdown();
      });

      test('sync executeQueryNamed binds @name/:name values', () async {
        final conn = await locator.syncService.connect(dsn);
        final connection =
            conn.getOrElse((_) => throw Exception('connect failed'));

        final result = await locator.syncService.executeQueryNamed(
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

        await locator.syncService.disconnect(connection.id);
      });

      test('async executeQueryNamed binds @name/:name values', () async {
        final conn = await locator.asyncService.connect(dsn);
        final connection =
            conn.getOrElse((_) => throw Exception('connect failed'));

        final result = await locator.asyncService.executeQueryNamed(
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

        await locator.asyncService.disconnect(connection.id);
      });

      test('sync executeQueryNamed supports more than five parameters',
          () async {
        final conn = await locator.syncService.connect(dsn);
        final connection =
            conn.getOrElse((_) => throw Exception('connect failed'));

        final result = await locator.syncService.executeQueryNamed(
          connection.id,
          'SELECT :a AS a, :b AS b, :c AS c, :d AS d, :e AS e, :f AS f',
          {
            'a': 1,
            'b': 2,
            'c': 3,
            'd': 4,
            'e': 5,
            'f': 6,
          },
        );
        expect(result.isSuccess(), isTrue, reason: '$result');
        result.fold(
          (success) {
            expect(success.rows, isNotEmpty);
            expect(success.rows.first, hasLength(6));
            expect(success.rows.first.first.toString(), equals('1'));
            expect(success.rows.first.last.toString(), equals('6'));
          },
          (_) => fail('executeQueryNamed should support >5 params'),
        );

        await locator.syncService.disconnect(connection.id);
      });

      test(
        'async executeQueryNamed supports more than five parameters',
        () async {
          final conn = await locator.asyncService.connect(dsn);
          final connection =
              conn.getOrElse((_) => throw Exception('connect failed'));

          final result = await locator.asyncService.executeQueryNamed(
            connection.id,
            'SELECT :a AS a, :b AS b, :c AS c, :d AS d, :e AS e, :f AS f',
            {
              'a': 7,
              'b': 8,
              'c': 9,
              'd': 10,
              'e': 11,
              'f': 12,
            },
          );
          expect(result.isSuccess(), isTrue, reason: '$result');
          result.fold(
            (success) {
              expect(success.rows, isNotEmpty);
              expect(success.rows.first, hasLength(6));
              expect(success.rows.first.first.toString(), equals('7'));
              expect(success.rows.first.last.toString(), equals('12'));
            },
            (_) => fail('async executeQueryNamed should support >5 params'),
          );

          await locator.asyncService.disconnect(connection.id);
        },
      );

      test('sync executeQueryNamed reuses repeated placeholder values',
          () async {
        final conn = await locator.syncService.connect(dsn);
        final connection =
            conn.getOrElse((_) => throw Exception('connect failed'));

        final result = await locator.syncService.executeQueryNamed(
          connection.id,
          'SELECT :id AS left_id, :id AS right_id',
          {'id': 321},
        );
        expect(result.isSuccess(), isTrue);
        result.fold(
          (success) {
            expect(success.rows, isNotEmpty);
            expect(success.rows.first, hasLength(2));
            expect(success.rows.first[0].toString(), equals('321'));
            expect(success.rows.first[1].toString(), equals('321'));
          },
          (_) => fail('executeQueryNamed should reuse repeated placeholders'),
        );

        await locator.syncService.disconnect(connection.id);
      });

      test('async prepareNamed + executePreparedNamed works', () async {
        final conn = await locator.asyncService.connect(dsn);
        final connection =
            conn.getOrElse((_) => throw Exception('connect failed'));

        final stmtResult = await locator.asyncService.prepareNamed(
          connection.id,
          'SELECT :v AS value_col',
        );
        final stmtId =
            stmtResult.getOrElse((_) => throw Exception('prepare failed'));

        final result = await locator.asyncService.executePreparedNamed(
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

        await locator.asyncService.closeStatement(connection.id, stmtId);
        await locator.asyncService.disconnect(connection.id);
      });

      test(
        'async prepareNamed + executePreparedNamed supports more than five '
        'parameters',
        () async {
          final conn = await locator.asyncService.connect(dsn);
          final connection =
              conn.getOrElse((_) => throw Exception('connect failed'));

          final stmtResult = await locator.asyncService.prepareNamed(
            connection.id,
            'SELECT :a AS a, :b AS b, :c AS c, :d AS d, :e AS e, :f AS f',
          );
          final stmtId =
              stmtResult.getOrElse((_) => throw Exception('prepare failed'));

          final result = await locator.asyncService.executePreparedNamed(
            connection.id,
            stmtId,
            {
              'a': 10,
              'b': 20,
              'c': 30,
              'd': 40,
              'e': 50,
              'f': 60,
            },
            null,
          );
          expect(result.isSuccess(), isTrue, reason: '$result');
          result.fold(
            (success) {
              expect(success.rows, isNotEmpty);
              expect(success.rows.first, hasLength(6));
              expect(success.rows.first.first.toString(), equals('10'));
              expect(success.rows.first.last.toString(), equals('60'));
            },
            (_) => fail('executePreparedNamed should support >5 params'),
          );

          await locator.asyncService.closeStatement(connection.id, stmtId);
          await locator.asyncService.disconnect(connection.id);
        },
      );

      test(
        'sync prepareNamed + executePreparedNamed supports more than five '
        'parameters',
        () async {
          final conn = await locator.syncService.connect(dsn);
          final connection =
              conn.getOrElse((_) => throw Exception('connect failed'));

          final stmtResult = await locator.syncService.prepareNamed(
            connection.id,
            'SELECT :a AS a, :b AS b, :c AS c, :d AS d, :e AS e, :f AS f',
          );
          final stmtId =
              stmtResult.getOrElse((_) => throw Exception('prepare failed'));

          final result = await locator.syncService.executePreparedNamed(
            connection.id,
            stmtId,
            {
              'a': 100,
              'b': 200,
              'c': 300,
              'd': 400,
              'e': 500,
              'f': 600,
            },
            null,
          );
          expect(result.isSuccess(), isTrue, reason: '$result');
          result.fold(
            (success) {
              expect(success.rows, isNotEmpty);
              expect(success.rows.first, hasLength(6));
              expect(success.rows.first.first.toString(), equals('100'));
              expect(success.rows.first.last.toString(), equals('600'));
            },
            (_) => fail(
              'sync executePreparedNamed should support >5 named params',
            ),
          );

          await locator.syncService.closeStatement(connection.id, stmtId);
          await locator.syncService.disconnect(connection.id);
        },
      );

      test('sync executePrepared supports more than five positional parameters',
          () async {
        final conn = await locator.syncService.connect(dsn);
        final connection =
            conn.getOrElse((_) => throw Exception('connect failed'));

        final stmtResult = await locator.syncService.prepare(
          connection.id,
          'SELECT ? AS a, ? AS b, ? AS c, ? AS d, ? AS e, ? AS f',
        );
        final stmtId =
            stmtResult.getOrElse((_) => throw Exception('prepare failed'));

        final result =
            await locator.syncService.executePreparedParamValuesFromObjects(
          connection.id,
          stmtId,
          [11, 22, 33, 44, 55, 66],
          null,
        );
        expect(result.isSuccess(), isTrue, reason: '$result');
        result.fold(
          (success) {
            expect(success.rows, isNotEmpty);
            expect(success.rows.first, hasLength(6));
            expect(success.rows.first.first.toString(), equals('11'));
            expect(success.rows.first.last.toString(), equals('66'));
          },
          (_) => fail('executePrepared should support >5 params'),
        );

        await locator.syncService.closeStatement(connection.id, stmtId);
        await locator.syncService.disconnect(connection.id);
      });

      test(
        'sync executeQueryMultiFull returns all result sets',
        skip: skipUnlessDatabase(
          [DatabaseType.sqlServer],
          reason: 'Multi-set SQL validated on SQL Server',
        ),
        () async {
          final conn = await locator.syncService.connect(dsn);
          final connection =
              conn.getOrElse((_) => throw Exception('connect failed'));

          final result = await locator.syncService.executeQueryMultiFull(
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

          await locator.syncService.disconnect(connection.id);
        },
      );

      test(
        'sync executeQueryMultiParams supports more than five positional '
        'parameters',
        skip: skipUnlessDatabase(
          [DatabaseType.sqlServer],
          reason: 'Multi-result parameterized SQL validated on SQL Server',
        ),
        () async {
          final conn = await locator.syncService.connect(dsn);
          final connection =
              conn.getOrElse((_) => throw Exception('connect failed'));

          final result =
              await locator.syncService.executeQueryMultiParamValuesFromObjects(
            connection.id,
            'SELECT ? AS a, ? AS b, ? AS c; SELECT ? AS d, ? AS e, ? AS f;',
            [1, 2, 3, 4, 5, 6],
          );
          expect(result.isSuccess(), isTrue, reason: '$result');
          result.fold(
            (success) {
              expect(success.resultSets.length, greaterThanOrEqualTo(2));
              expect(
                success.resultSets.first.rows.first.first.toString(),
                equals('1'),
              );
              expect(
                success.resultSets[1].rows.first.last.toString(),
                equals('6'),
              );
            },
            (_) => fail('executeQueryMultiParams should support >5 params'),
          );

          await locator.syncService.disconnect(connection.id);
        },
      );

      test('sync streamQueryNamed yields single chunk with correct rows',
          () async {
        final conn = await locator.syncService.connect(dsn);
        final connection =
            conn.getOrElse((_) => throw Exception('connect failed'));

        final chunks = await locator.syncService.streamQueryNamed(
          connection.id,
          'SELECT 1 AS n WHERE 1 = :v',
          {'v': 1},
        ).toList();

        expect(chunks, hasLength(1));
        expect(chunks.first.isSuccess(), isTrue);
        final result =
            chunks.first.getOrElse((_) => throw Exception('expected success'));
        expect(result.rows, hasLength(1));
        expect(result.rows.first.first.toString(), equals('1'));

        await locator.syncService.disconnect(connection.id);
      });

      test('sync streamQueryNamed yields failure for missing named param',
          () async {
        final conn = await locator.syncService.connect(dsn);
        final connection =
            conn.getOrElse((_) => throw Exception('connect failed'));

        final chunks = await locator.syncService.streamQueryNamed(
          connection.id,
          'SELECT 1 WHERE 1 = :missing',
          <String, Object?>{},
        ).toList();

        expect(chunks, hasLength(1));
        expect(chunks.first.isError(), isTrue);

        await locator.syncService.disconnect(connection.id);
      });
    },
    skip: skipUnlessLiveOdbcTest(),
  );
}

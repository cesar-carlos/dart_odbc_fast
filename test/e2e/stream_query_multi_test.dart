/// E2E: `streamQueryMulti` against a portable multi-statement SELECT batch.
///
/// Requires `ENABLE_E2E_TESTS=1`, `RUN_LIVE_TESTS=1`, and `ODBC_TEST_DSN`.
library;

import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group(
    'streamQueryMulti E2E',
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
        'should stream result sets for SELECT batch (sync)',
        () async {
          final connResult = await locator!.syncService.connect(dsn);
          final connection = connResult.getOrNull();
          expect(
            connection,
            isNotNull,
            reason: '${connResult.exceptionOrNull()}',
          );

          try {
            final items = <QueryResultMultiItem>[];
            await for (final chunk in locator!.syncService.streamQueryMulti(
              connection!.id,
              'SELECT 1 AS a; SELECT 2 AS b',
            )) {
              chunk.fold(
                items.add,
                (e) => fail('streamQueryMulti failed: $e'),
              );
            }
            expect(items, isNotEmpty);
            final resultSetCount =
                items.where((item) => item.isResultSet).length;
            expect(resultSetCount, greaterThanOrEqualTo(1));
          } finally {
            await locator!.syncService.disconnect(connection!.id);
          }
        },
      );

      test(
        'should stream result sets for SELECT batch (async)',
        () async {
          final connResult = await locator!.asyncService.connect(dsn);
          final connection = connResult.getOrNull();
          expect(
            connection,
            isNotNull,
            reason: '${connResult.exceptionOrNull()}',
          );

          try {
            final items = <QueryResultMultiItem>[];
            await for (final chunk in locator!.asyncService.streamQueryMulti(
              connection!.id,
              'SELECT 1 AS a; SELECT 2 AS b',
            )) {
              chunk.fold(
                items.add,
                (e) => fail('streamQueryMulti failed: $e'),
              );
            }
            expect(items, isNotEmpty);
          } finally {
            await locator!.asyncService.disconnect(connection!.id);
          }
        },
      );
    },
    skip: skipUnlessE2eTest(),
  );
}

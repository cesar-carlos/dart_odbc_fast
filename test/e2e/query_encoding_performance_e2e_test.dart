/// E2E regression / performance checks for QueryResult vs columnar encoding,
/// stream chunk sizing, prepared reuse, and bulk insert.
///
/// Requires ENABLE_E2E_TESTS=1, RUN_LIVE_TESTS=1, and ODBC_TEST_DSN.
/// Set RUN_PERF_TESTS=1 to print timing comparisons.
library;

import 'dart:typed_data';

import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/infrastructure/native/protocol/bulk_insert_builder.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

const _table = 'e2e_perf_encoding';

void main() {
  loadTestEnv();

  group(
    'Query encoding performance E2E',
    () {
      ServiceLocator? locator;
      var dsn = '';
      var connectionId = '';

      setUpAll(() async {
        dsn = getTestEnv('ODBC_TEST_DSN') ?? '';
        try {
          final sl = ServiceLocator()
            ..initialize(profile: OdbcUsageProfile.balancedServer);
          await sl.service.initialize();
          locator = sl;
        } on Object catch (e, st) {
          markTestSkipped('Native environment unavailable: $e\n$st');
        }
      });

      tearDownAll(() {
        locator?.shutdown();
      });

      setUp(() async {
        final sl = locator!;
        final conn = await sl.service.connect(
          dsn,
          options: sl.recommendedConnectionOptions,
        );
        final connection = conn.getOrNull();
        expect(
          connection,
          isNotNull,
          reason: '${conn.exceptionOrNull()}',
        );
        connectionId = connection!.id;

        await sl.service.executeQuery(
          "IF OBJECT_ID(N'$_table', N'U') IS NOT NULL DROP TABLE $_table",
          connectionId: connectionId,
        );
        await sl.service.executeQuery(
          'CREATE TABLE $_table (id INT NOT NULL, val NVARCHAR(64) NOT NULL)',
          connectionId: connectionId,
        );
      });

      tearDown(() async {
        final sl = locator;
        if (sl == null || connectionId.isEmpty) return;
        await sl.service.executeQuery(
          "IF OBJECT_ID(N'$_table', N'U') IS NOT NULL DROP TABLE $_table",
          connectionId: connectionId,
        );
        await sl.service.disconnect(connectionId);
        connectionId = '';
      });

      test(
        'should_match_row_and_columnar_results_when_selecting_same_sql',
        () async {
          final sl = locator!;
          expect(
            sl.recommendedResultEncoding,
            ResultEncoding.columnar,
          );
          expect(
            forQueryResultWire(sl.recommendedResultEncoding),
            ResultEncoding.rowMajor,
          );

          final insert = await sl.service.executeQuery(
            "INSERT INTO $_table (id, val) VALUES (1, N'a'), (2, N'b')",
            connectionId: connectionId,
          );
          expect(
            insert.isSuccess(),
            isTrue,
            reason: '${insert.exceptionOrNull()}',
          );

          const sql = 'SELECT id, val FROM $_table ORDER BY id';

          final rowWatch = Stopwatch()..start();
          final rowResult = await sl.service.executeQueryParamValues(
            connectionId,
            sql,
            const [],
          );
          rowWatch.stop();

          final colWatch = Stopwatch()..start();
          final colResult = await sl.service.executeQueryColumnarParamValues(
            connectionId,
            sql,
          );
          colWatch.stop();

          expect(
            rowResult.isSuccess(),
            isTrue,
            reason: '${rowResult.exceptionOrNull()}',
          );
          expect(
            colResult.isSuccess(),
            isTrue,
            reason: '${colResult.exceptionOrNull()}',
          );

          final rows = rowResult.getOrNull()!;
          final typed = colResult.getOrNull()!;

          expect(rows.rowCount, 2);
          expect(typed.rowCount, 2);
          expect(rows.columns.length, typed.columns.length);

          final idCol = typed.columns.first as TypedColumnInt32;
          expect(idCol.values[0], rows.rows[0][0]);
          expect(idCol.values[1], rows.rows[1][0]);
          expect(typed.columns[1].isNullAt(0), isFalse);
          // LazyString (server preset) equals String when LazyString is the
          // receiver; String.expect equality checks type, so assert via ==.
          expect(rows.rows[0][1] == 'a', isTrue);
          expect(rows.rows[1][1] == 'b', isTrue);

          if (runPerformanceTests) {
            print(
              'parity SELECT: row=${rowWatch.elapsedMicroseconds}us '
              'columnar=${colWatch.elapsedMicroseconds}us',
            );
          }
        },
      );

      test(
        'should_stream_with_recommended_chunk_size_when_server_profile',
        () async {
          final sl = locator!;
          final insert = await sl.service.executeQuery(
            'INSERT INTO $_table (id, val) '
            "VALUES (1, N'x'), (2, N'y'), (3, N'z')",
            connectionId: connectionId,
          );
          expect(insert.isSuccess(), isTrue);

          final chunkSize = sl.recommendedStreamChunkSizeBytes;
          expect(chunkSize, 1024 * 1024);

          var totalRows = 0;
          await for (final chunk in sl.service.streamQuery(
            connectionId,
            'SELECT id, val FROM $_table ORDER BY id',
            chunkSize: chunkSize,
          )) {
            expect(
              chunk.isSuccess(),
              isTrue,
              reason: '${chunk.exceptionOrNull()}',
            );
            totalRows += chunk.getOrNull()!.rowCount;
          }
          expect(totalRows, greaterThanOrEqualTo(3));

          totalRows = 0;
          await for (final item in sl.service.streamQueryMulti(
            connectionId,
            'SELECT id FROM $_table',
            chunkSize: chunkSize,
          )) {
            expect(
              item.isSuccess(),
              isTrue,
              reason: '${item.exceptionOrNull()}',
            );
            final multiItem = item.getOrNull()!;
            if (multiItem.isResultSet) {
              totalRows += multiItem.resultSet!.rowCount;
            }
          }
          expect(totalRows, greaterThanOrEqualTo(3));
        },
      );

      test(
        'should_reuse_prepared_statement_with_parity_when_executing_repeatedly',
        () async {
          final sl = locator!;
          final insert = await sl.service.executeQuery(
            "INSERT INTO $_table (id, val) VALUES (10, N'p')",
            connectionId: connectionId,
          );
          expect(insert.isSuccess(), isTrue);

          const sql = 'SELECT id, val FROM $_table WHERE id = ?';
          const rounds = 20;

          final prep = await sl.service.prepare(connectionId, sql);
          expect(prep.isSuccess(), isTrue, reason: '${prep.exceptionOrNull()}');
          final stmtId = prep.getOrNull()!;

          final preparedWatch = Stopwatch()..start();
          Object? preparedFirst;
          for (var i = 0; i < rounds; i++) {
            final r = await sl.service.executePreparedParamValues(
              connectionId,
              stmtId,
              [const ParamValueInt32(10)],
              null,
            );
            expect(r.isSuccess(), isTrue, reason: '${r.exceptionOrNull()}');
            preparedFirst ??= r.getOrNull()!.rows.single.first;
          }
          preparedWatch.stop();

          final adHocWatch = Stopwatch()..start();
          Object? adHocFirst;
          for (var i = 0; i < rounds; i++) {
            final r = await sl.service.executeQueryParamValues(
              connectionId,
              sql,
              [const ParamValueInt32(10)],
            );
            expect(r.isSuccess(), isTrue, reason: '${r.exceptionOrNull()}');
            adHocFirst ??= r.getOrNull()!.rows.single.first;
          }
          adHocWatch.stop();

          expect(preparedFirst, adHocFirst);
          expect(preparedFirst, 10);

          await sl.service.closeStatement(connectionId, stmtId);

          if (runPerformanceTests) {
            print(
              'prepared reuse ($rounds): '
              'prepared=${preparedWatch.elapsedMicroseconds}us '
              'adHoc=${adHocWatch.elapsedMicroseconds}us',
            );
          }
        },
      );

      test(
        'should_bulk_insert_uint8list_from_columnar_builder_without_failure',
        () async {
          final sl = locator!;
          final ids = Int32List.fromList([1, 2, 3]);
          final buffer = (BulkInsertBuilder()
                ..table(_table)
                ..addColumnInt32('id', ids)
                ..addColumnText(
                  'val',
                  ['one', 'two', 'three'],
                  maxLen: 64,
                ))
              .build();
          expect(buffer, isA<Uint8List>());

          final result = await sl.service.bulkInsert(
            connectionId,
            _table,
            ['id', 'val'],
            buffer,
            3,
          );
          expect(
            result.isSuccess(),
            isTrue,
            reason: '${result.exceptionOrNull()}',
          );
          expect(result.getOrNull(), greaterThanOrEqualTo(0));

          final count = await sl.service.executeQuery(
            'SELECT COUNT(*) AS c FROM $_table',
            connectionId: connectionId,
          );
          expect(
            count.isSuccess(),
            isTrue,
            reason: '${count.exceptionOrNull()}',
          );
          expect(count.getOrNull()!.rows.single.first, 3);
        },
      );
    },
    skip: skipUnlessE2eTest(),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

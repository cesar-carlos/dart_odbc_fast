/// Optional E2E: SQL Server stored procedure with multiple result sets AND an
/// `OUTPUT` parameter + DRT1 (directed).
///
/// Validates the MULT envelope path: when a stored procedure executes a
/// `SELECT`, then DML (INSERT / UPDATE into a table variable), then another
/// `SELECT`, and also has an `INT OUTPUT`, the engine emits a `MULT` frame
/// followed by `OUT1`.
/// The Dart parser surfaces:
///   - the first `SELECT` in `QueryResult.columns` / `rows` / `rowCount`,
///   - the tail items (row-count from INSERT + second result set) in
///     `QueryResult.additionalResults`, and
///   - the scalar `OUT` value in `QueryResult.outputParamValues`.
///
/// The procedure uses a table variable (not a temp table) so it is fully
/// self-contained: each call gets its own scoped storage and the test does not
/// depend on objects created in a different connection.
///
/// Requires **Microsoft SQL Server** with *ODBC Driver 17+ for SQL Server*
/// (or *Native Client 11.0*) and a login that can `CREATE`/`DROP` in `dbo`.
///
/// Enable with:
///   `E2E_MSSQL_DIRECTED_OUT_MULTI=1  ODBC_TEST_DSN=<sql-server-dsn>`
///
/// Run:
///   `dart test test/e2e/mssql_directed_out_multi_rset_test.dart`
///
/// Runs on the **host** (Dart + local ODBC), not inside `scripts/docker_e2e`.
library;

import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/domain/entities/query_result.dart'
    show DirectedResultItem;
import 'package:odbc_fast/domain/types/param_direction.dart';
import 'package:odbc_fast/infrastructure/native/protocol/directed_param.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

const _procName = 'odbc_e2e_directed_out_multi';

/// Procedure: returns two result sets (one before DML, one after) and an
/// `INT OUTPUT`.  `SET NOCOUNT OFF` (default) so the INSERT row-count appears
/// as an intermediate result in `SQLMoreResults`.
///
/// A table variable is used instead of a temp table so the procedure is
/// fully self-contained and independent of any connection-scoped objects.
const _sqlCreate = '''
CREATE PROCEDURE dbo.$_procName
  @val int OUTPUT
AS
BEGIN
  -- First result set
  SELECT 1 AS n, 'first' AS label;

  -- Row-count result from DML (table variable — self-contained per call)
  DECLARE @t TABLE (x INT);
  INSERT INTO @t (x) VALUES (99);

  -- Second result set
  SELECT 2 AS n, 'second' AS label;

  SET @val = 42;
END
''';

const _sqlDrop = '''
IF OBJECT_ID(N'dbo.$_procName', N'P') IS NOT NULL
  DROP PROCEDURE dbo.$_procName;
''';

const _sqlCall = '{CALL dbo.$_procName(?)}';

const _kSkipEnv =
    'Set E2E_MSSQL_DIRECTED_OUT_MULTI=1 and ODBC_TEST_DSN to a SQL Server '
    'DSN with ODBC Driver 17+, then run on a host with the ODBC driver';

final _directedOut = <DirectedParam>[
  const DirectedParam(
    value: 0,
    type: SqlDataType.int32,
    direction: ParamDirection.output,
  ),
];

void main() {
  loadTestEnv();
  final hasDsn = getTestEnv('ODBC_TEST_DSN')?.isNotEmpty ?? false;
  final envOn = getTestEnv('E2E_MSSQL_DIRECTED_OUT_MULTI') == '1';
  final isSql = isDatabaseType([DatabaseType.sqlServer]);
  final run = envOn && hasDsn && isSql;

  group('SQL Server directed OUT + multi-result (MULT path)', () {
    ServiceLocator? locator;
    var dsn = '';
    String? initFailure;

    setUpAll(() async {
      if (!run) return;
      dsn = getTestEnv('ODBC_TEST_DSN') ?? '';
      if (dsn.isEmpty) {
        initFailure = 'ODBC_TEST_DSN is empty';
        return;
      }
      try {
        final sl = ServiceLocator()..initialize(useAsync: true);
        await sl.syncService.initialize();
        await sl.asyncService.initialize();
        locator = sl;
      } on Object catch (e) {
        initFailure = 'Native environment unavailable: $e';
        return;
      }
      if (locator == null) return;
      try {
        final cr = await locator!.syncService.connect(dsn);
        final c = cr.getOrElse(
          (_) => throw Exception('setUp connect failed'),
        );
        try {
          await locator!.syncService.executeQueryParams(
            c.id, _sqlDrop, <dynamic>[],
          );
          final result = await locator!.syncService.executeQueryParams(
            c.id, _sqlCreate, <dynamic>[],
          );
          if (!result.isSuccess()) {
            initFailure =
                'CREATE PROCEDURE failed: ${result.exceptionOrNull()}';
          }
        } finally {
          await locator!.syncService.disconnect(c.id);
        }
      } on Object catch (e) {
        initFailure = 'DDL: $e';
      }
    });

    tearDownAll(() async {
      if (run && locator != null && dsn.isNotEmpty) {
        try {
          final cr = await locator!.syncService.connect(dsn);
          final c = cr.getOrElse(
            (_) => throw Exception('teardown connect failed'),
          );
          try {
            await locator!.syncService.executeQueryParams(
              c.id, _sqlDrop, <dynamic>[],
            );
          } finally {
            await locator!.syncService.disconnect(c.id);
          }
        } on Object {
          // Best-effort cleanup.
        }
      }
      locator?.shutdown();
    });

    test(
      'CALL with OUT int + two result sets:',
      () async {
        // Primary result set -> QueryResult rows/columns.
        // Tail items -> QueryResult.additionalResults.
        // Scalar OUTPUT -> QueryResult.outputParamValues.
        if (initFailure != null || locator == null) {
          fail(initFailure ?? 'ServiceLocator is null');
        }

        final cr = await locator!.syncService.connect(dsn);
        final conn = cr.getOrElse(
          (_) => throw Exception('connect failed'),
        );
        try {
          final callResult =
              await locator!.syncService.executeQueryDirectedParams(
            conn.id,
            _sqlCall,
            _directedOut,
          );
          expect(
            callResult.isSuccess(),
            isTrue,
            reason:
                'CALL multi-result + OUT (sync): '
                '${callResult.exceptionOrNull()}',
          );
          callResult.fold(
            (q) {
              // Primary result set: first SELECT (n=1, label='first').
              expect(q.rowCount, 1, reason: 'primary RS must have 1 row');
              expect(q.columns, contains('n'));

              // OUT1 scalar.
              expect(
                q.hasOutputParamValues,
                isTrue,
                reason: 'OUT int must be present',
              );
              expect(
                (q.outputParamValues[0] as ParamValueInt32).value,
                42,
              );

              // Additional results: row-count from INSERT + second SELECT.
              expect(
                q.hasAdditionalResults,
                isTrue,
                reason: 'additionalResults must be non-empty',
              );
              final tail = q.additionalResults;
              // Depending on NOCOUNT, there may be a RowCount item before the
              // second ResultSet.  Accept either [RowCount, ResultSet] or just
              // [ResultSet].
              final resultItems =
                  tail.whereType<DirectedResultItem>().toList();
              expect(
                resultItems,
                isNotEmpty,
                reason: 'at least one additional result set expected',
              );
              final second = resultItems.first;
              expect(
                second.rowCount,
                1,
                reason: 'second result set must have 1 row',
              );
            },
            (err) => fail('CALL should succeed, got: $err'),
          );
        } finally {
          await locator!.syncService.disconnect(conn.id);
        }
      },
      skip: run ? false : _kSkipEnv,
    );

    test(
      'async service: same MULT + OUT1 assertions',
      () async {
        if (initFailure != null || locator == null) {
          fail(initFailure ?? 'ServiceLocator is null');
        }

        final cr = await locator!.asyncService.connect(dsn);
        final conn = cr.getOrElse(
          (_) => throw Exception('connect failed'),
        );
        try {
          final callResult =
              await locator!.asyncService.executeQueryDirectedParams(
            conn.id,
            _sqlCall,
            _directedOut,
          );
          expect(
            callResult.isSuccess(),
            isTrue,
            reason:
                'CALL multi-result + OUT (async): '
                '${callResult.exceptionOrNull()}',
          );
          callResult.fold(
            (q) {
              expect(q.rowCount, 1);
              expect(
                (q.outputParamValues[0] as ParamValueInt32).value,
                42,
              );
              expect(q.hasAdditionalResults, isTrue);
            },
            (err) => fail('async CALL should succeed, got: $err'),
          );
        } finally {
          await locator!.asyncService.disconnect(conn.id);
        }
      },
      skip: run ? false : _kSkipEnv,
    );
  });
}

/// Optional E2E: SQL Server stored procedure with `OUTPUT` + DRT1 (directed).
///
/// Requires **Microsoft SQL Server**, a login that may `CREATE`/`DROP` in
/// `dbo`,
/// and an ODBC driver that supports `OUT` binding (e.g. *ODBC Driver 17/18 for
/// SQL Server*).
///
/// Set `E2E_MSSQL_DIRECTED_OUT=1` and `ODBC_TEST_DSN` to a **SQL Server** DSN,
/// then run:
/// `dart test test/e2e/mssql_directed_out_test.dart`
///
/// Runs on the **host** (Dart + local ODBC), not inside `scripts/docker_e2e`
/// (Rust-only `test-runner`). Use the SQL Server line from the `docker_db_up`
/// cheatsheet if you point at the Docker `mssql` service from Windows.
library;

import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/domain/types/param_direction.dart';
import 'package:odbc_fast/infrastructure/native/protocol/directed_param.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

const _procName = 'odbc_e2e_directed_out';

/// First batch: `CREATE PROCEDURE` must be the only statement in its batch.
/// One `INT` output (reliable on **SQL Server Native Client 11.0** + DRT1).
/// Some clients error with `8000`/`8018` when a second *wide* `OUTPUT` is bound
/// (deprecated LOB) — use **ODBC Driver 17+ for SQL Server** for *multi* `OUT`
/// (see `doc/development/docker-test-stack.md`).
const _sqlCreate = '''
CREATE PROCEDURE dbo.$_procName
  @a int OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  SET @a = 42;
END
''';

const _sqlDrop = '''
IF OBJECT_ID(N'dbo.$_procName', N'P') IS NOT NULL
  DROP PROCEDURE dbo.$_procName;
''';

/// ODBC procedure call with positional `?` for each OUTPUT (engine DRT1).
const _sqlCall = '{CALL dbo.$_procName(?)}';

const _kSkipEnv =
    'Set E2E_MSSQL_DIRECTED_OUT=1 and ODBC_TEST_DSN to a SQL Server DSN, '
    'then run on a host with the SQL Server ODBC driver';

// Integer `OUT` wire shell: [SqlDataType.int32] with a dummy `0` (not `null`
// only), matching [TYPE_MAPPING] §3.1 / [output_aware_params] (avoid two
// consecutive `ParamValue::Null` mis-binding).
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
  final envOn = getTestEnv('E2E_MSSQL_DIRECTED_OUT') == '1';
  final isSql = isDatabaseType([DatabaseType.sqlServer]);
  final run = envOn && hasDsn && isSql;

  group('SQL Server directed OUT (DRT1)', () {
    ServiceLocator? locator;
    var dsn = '';
    String? initFailure;

    setUpAll(() async {
      if (!run) {
        return;
      }
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
      if (initFailure != null || locator == null) {
        return;
      }
      try {
        final connectResult = await locator!.syncService.connect(dsn);
        final c = connectResult.getOrElse(
          (_) => throw Exception('setUp connect failed'),
        );
        try {
          await locator!.syncService.executeQueryParams(
            c.id,
            _sqlDrop,
            <dynamic>[],
          );
          final createResult = await locator!.syncService.executeQueryParams(
            c.id,
            _sqlCreate,
            <dynamic>[],
          );
          if (!createResult.isSuccess()) {
            initFailure = 'CREATE PROCEDURE failed: '
                '${createResult.exceptionOrNull()}';
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
          final connectResult = await locator!.syncService.connect(dsn);
          final c = connectResult.getOrElse(
            (_) => throw Exception('teardown connect failed'),
          );
          try {
            await locator!.syncService.executeQueryParams(
              c.id,
              _sqlDrop,
              <dynamic>[],
            );
          } finally {
            await locator!.syncService.disconnect(c.id);
          }
        } on Object {
          // Best-effort cleanup
        }
      }
      locator?.shutdown();
    });

    test(
      'SELECT 1 smoke, CALL with OUT int, assert OUT1 (sync)',
      () async {
        if (initFailure != null || locator == null) {
          fail(initFailure ?? 'ServiceLocator is null');
        }

        final connectResult = await locator!.syncService.connect(dsn);
        final connection = connectResult.getOrElse(
          (_) => throw Exception('connect failed'),
        );
        final connectionId = connection.id;
        try {
          final smoke = await locator!.syncService.executeQueryParams(
            connectionId,
            'SELECT 1',
            <dynamic>[],
          );
          expect(smoke.isSuccess(), isTrue, reason: 'SELECT 1 should succeed');

          final callResult =
              await locator!.syncService.executeQueryDirectedParams(
            connectionId,
            _sqlCall,
            _directedOut,
          );
          expect(
            callResult.isSuccess(),
            isTrue,
            reason: 'CALL with OUT (sync): ${callResult.exceptionOrNull()}',
          );
          callResult.fold(
            (q) {
              expect(q.hasOutputParamValues, isTrue);
              final outs = q.outputParamValues;
              expect(outs, hasLength(1));
              final v0 = outs[0];
              expect(
                v0,
                isA<ParamValueInt32>(),
                reason: 'OUT int -> ParamValueInt32, got $v0',
              );
              expect((v0! as ParamValueInt32).value, 42);
            },
            (err) {
              fail('CALL (sync) should return Success, got: $err');
            },
          );
        } finally {
          await locator!.syncService.disconnect(connectionId);
        }
      },
      skip: run
          ? false
          : (!envOn || !hasDsn)
              ? _kSkipEnv
              : 'ODBC_TEST_DSN is not a SQL Server DSN (directed OUT is for '
                  'mssql only)',
    );

    test(
      'async service: same CALL and OUT1 assertions',
      () async {
        if (initFailure != null || locator == null) {
          fail(initFailure ?? 'ServiceLocator is null');
        }

        final connectResult = await locator!.asyncService.connect(dsn);
        final connection = connectResult.getOrElse(
          (_) => throw Exception('connect failed'),
        );
        final connectionId = connection.id;
        try {
          final callResult =
              await locator!.asyncService.executeQueryDirectedParams(
            connectionId,
            _sqlCall,
            _directedOut,
          );
          expect(
            callResult.isSuccess(),
            isTrue,
            reason: 'CALL with OUT (async): ${callResult.exceptionOrNull()}',
          );
          callResult.fold(
            (q) {
              final outs = q.outputParamValues;
              expect(outs, hasLength(1));
              expect((outs[0] as ParamValueInt32).value, 42);
            },
            (err) {
              fail('CALL (async) should return Success, got: $err');
            },
          );
        } finally {
          await locator!.asyncService.disconnect(connectionId);
        }
      },
      skip: run
          ? false
          : (!envOn || !hasDsn)
              ? _kSkipEnv
              : 'ODBC_TEST_DSN is not a SQL Server DSN (directed OUT is for '
                  'mssql only)',
    );
  });
}

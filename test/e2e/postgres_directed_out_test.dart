/// Optional E2E: PostgreSQL `CALL` / `OUT` with DRT1 (directed parameters).
///
/// Requires **PostgreSQL 11+** (`CREATE PROCEDURE` with `OUT` parameters) and
/// a user that may `CREATE` in schema `public`. Validated with the
/// `PostgreSQL Unicode` driver (DSN in `ODBC_TEST_DSN`); other drivers may
/// differ in bind or `CALL` support.
///
/// Set `E2E_PG_DIRECTED_OUT=1` and a non-empty `ODBC_TEST_DSN` to your
/// PostgreSQL DSN, then run:
/// `dart test test/e2e/postgres_directed_out_test.dart`
///
/// This test runs on the **host** (Dart + local ODBC), not in
/// `scripts/docker_e2e` (Rust-only in the `test-runner` image). See
/// `doc/development/docker-test-stack.md` (optional PG section).
library;

import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/domain/types/param_direction.dart';
import 'package:odbc_fast/infrastructure/native/protocol/directed_param.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

/// Stable object name; created in the `public` schema for typical docker/local
/// PG DSNs.
const _procName = 'odbc_e2e_directed_out';

const _ddlCreate = '''
CREATE OR REPLACE PROCEDURE public.$_procName(OUT a integer, OUT b text)
LANGUAGE plpgsql
AS \$\$
BEGIN
  a := 42;
  b := 'odbc-pg-out';
END;
\$\$;
''';

const _sqlDrop = 'DROP PROCEDURE IF EXISTS public.$_procName(integer, text);';

const _sqlCall = 'CALL public.$_procName(?, ?)';

const _kSkipEnv =
    'Set E2E_PG_DIRECTED_OUT=1 and ODBC_TEST_DSN, then run on a host '
    'with PostgreSQL 11+ and the PG ODBC driver';

final _directedOut = <DirectedParam>[
  const DirectedParam(
    value: null,
    type: SqlDataType.int32,
    direction: ParamDirection.output,
  ),
  DirectedParam(
    value: null,
    type: SqlDataType.varChar(),
    direction: ParamDirection.output,
  ),
];

void main() {
  loadTestEnv();
  final run = getTestEnv('E2E_PG_DIRECTED_OUT') == '1' &&
      (getTestEnv('ODBC_TEST_DSN')?.isNotEmpty ?? false);

  group('PostgreSQL directed OUT (DRT1)', () {
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
            _ddlCreate,
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
          // Best-effort cleanup; ignore if DB already torn down.
        }
      }
      locator?.shutdown();
    });

    test(
      'SELECT 1 smoke, CALL with OUT int + text, assert OUT1 (sync)',
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
            reason: 'CALL with OUT (sync)',
          );
          callResult.fold(
            (q) {
              expect(q.hasOutputParamValues, isTrue);
              final outs = q.outputParamValues;
              expect(outs, hasLength(2));
              final v0 = outs[0];
              final v1 = outs[1];
              expect(
                v0,
                isA<ParamValueInt32>(),
                reason: 'OUT integer -> ParamValueInt32, got $v0',
              );
              expect((v0! as ParamValueInt32).value, 42);
              expect(
                v1,
                isA<ParamValueString>(),
                reason: 'OUT text -> ParamValueString, got $v1',
              );
              expect((v1! as ParamValueString).value, 'odbc-pg-out');
            },
            (err) {
              fail('CALL (sync) should return Success, got: $err');
            },
          );
        } finally {
          await locator!.syncService.disconnect(connectionId);
        }
      },
      skip: run ? false : _kSkipEnv,
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
            reason: 'CALL with OUT (async)',
          );
          callResult.fold(
            (q) {
              final outs = q.outputParamValues;
              expect(outs, hasLength(2));
              final o0 = outs[0] as ParamValueInt32;
              final o1 = outs[1] as ParamValueString;
              expect(o0.value, 42);
              expect(o1.value, 'odbc-pg-out');
            },
            (err) {
              fail('CALL (async) should return Success, got: $err');
            },
          );
        } finally {
          await locator!.asyncService.disconnect(connectionId);
        }
      },
      skip: run ? false : _kSkipEnv,
    );
  });
}

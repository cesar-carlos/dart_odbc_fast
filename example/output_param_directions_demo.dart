// Demonstrates DRT1 [serializeDirectedParams] and
// [IOdbcService.executeQueryDirectedParams].
//
// Native support covers scalar/text `OUT` / `INOUT`, `OUT1` result trailers,
// `MULT + OUT1` for stored procedures that return extra result items, and the
// Oracle-only `ParamValueRefCursorOut` marker. Binary `OUT` / `INOUT`, TVP and
// the exhaustive `SqlDataType` x direction matrix remain product-gated; see
// `doc/notes/TYPE_MAPPING.md` section 3.1.
//
// Run: `dart run example/output_param_directions_demo.dart`
// Optional: set `ODBC_TEST_DSN` (see `example/common.dart`) to run a live
// `SELECT CAST(? AS INT)` with a directed *input* parameter (same DRT1 path).

import 'package:odbc_fast/odbc_fast.dart';
import 'package:odbc_fast/odbc_fast_native.dart';

import 'common.dart';

void main() async {
  AppLogger.initialize();

  final drt1 = serializeDirectedParams([
    const DirectedParam(value: 1),
    const DirectedParam(
      value: null,
      direction: ParamDirection.output,
    ),
  ]);
  AppLogger.info(
    'DRT1 sample: ${drt1.length} bytes (OUT slot as ParamValueNull)',
  );

  final inOnly = paramValuesFromDirected([
    const DirectedParam(value: 42),
    DirectedParam(
      value: 'hi',
      type: SqlDataType.nVarChar(length: 40),
    ),
  ]);
  AppLogger.info(
    'Legacy v0 from directed (input-only): ${inOnly.length} params',
  );

  final textOut = serializeDirectedParams([
    DirectedParam(
      value: '',
      type: SqlDataType.nVarChar(length: 128),
      direction: ParamDirection.output,
    ),
    const DirectedParam(
      value: 1,
      type: SqlDataType.int32,
      direction: ParamDirection.inOut,
    ),
  ]);
  AppLogger.info(
    'DRT1 scalar/text OUT+INOUT sample: ${textOut.length} bytes',
  );

  final oracleRefCursor = serializeDirectedParams([
    const DirectedParam(
      value: ParamValueRefCursorOut(),
      direction: ParamDirection.output,
    ),
  ]);
  AppLogger.info(
    'DRT1 Oracle REF CURSOR marker sample: ${oracleRefCursor.length} bytes '
    '(rows arrive later in QueryResult.refCursorResults via RC1 trailer)',
  );

  try {
    serializeDirectedParams([
      DirectedParam(
        value: <int>[1, 2, 3],
        type: SqlDataType.varBinary(),
        direction: ParamDirection.output,
      ),
    ]);
  } on Object catch (e) {
    AppLogger.info('Binary OUT is intentionally rejected: $e');
  }

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final native = NativeOdbcConnection();
  final repository = OdbcRepositoryImpl(native);
  final service = OdbcService(repository);

  if ((await service.initialize()).isError()) {
    AppLogger.severe('initialize failed');
    return;
  }
  final connect = await service.connect(
    dsn,
    options: const ConnectionOptions(),
  );
  if (connect.isError()) {
    AppLogger.severe('connect: ${connect.exceptionOrNull()}');
    return;
  }
  final connId = connect.getOrThrow().id;
  try {
    final r = await service.executeQueryDirectedParams(
      connId,
      'SELECT CAST(? AS INT) AS x',
      const [DirectedParam(value: 7)],
    );
    r.fold(
      (ok) => AppLogger.info(
        'executeQueryDirectedParams: rowCount=${ok.rowCount} '
        'out=${ok.outputParamValues.length}',
      ),
      (e) => AppLogger.severe('query: $e'),
    );
    AppLogger.info(
      'For live OUT1 and MULT + OUT1 stored-procedure checks, run '
      'test/e2e/mssql_directed_out_test.dart or '
      'test/e2e/mssql_directed_out_multi_rset_test.dart with their opt-in env.',
    );
  } finally {
    await service.disconnect(connId);
  }
}

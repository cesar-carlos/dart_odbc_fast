// Demonstrates DRT1 [serializeDirectedParams] and
// [IOdbcService.executeQueryDirectedParams] (MVP: integer `OUT`/`INOUT` in
// the native engine; see `doc/notes/TYPE_MAPPING.md` §3.1).
//
// Run: `dart run example/output_param_directions_demo.dart`
// Optional: set `ODBC_TEST_DSN` (see `example/common.dart`) to run a live
// `SELECT CAST(? AS INT)` with a directed *input* parameter (same DRT1 path).

import 'package:odbc_fast/odbc_fast.dart';

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
  } finally {
    await service.disconnect(connId);
  }
}

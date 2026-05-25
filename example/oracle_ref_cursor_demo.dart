// Opt-in Oracle SYS_REFCURSOR example.
//
// The Oracle ODBC path uses a DRT1 `ParamValueRefCursorOut` marker. The native
// engine strips the corresponding `?`, executes the call, reads cursor result
// sets with SQLMoreResults, and exposes them in QueryResult.refCursorResults
// via the RC1 trailer.
//
// Run only against an Oracle DSN and a procedure that returns SYS_REFCURSOR:
//
//   ODBC_TEST_DSN=...
//   ODBC_ORACLE_REFCURSOR_CALL="{CALL my_pkg.open_cursor(?)}"
//   dart run example/oracle_ref_cursor_demo.dart

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

void main() async {
  AppLogger.initialize();

  final sql = Platform.environment['ODBC_ORACLE_REFCURSOR_CALL'];
  if (sql == null || sql.isEmpty) {
    const message =
        'ODBC_ORACLE_REFCURSOR_CALL not set; skipping Oracle ref cursor demo.';
    stderr.writeln(message);
    AppLogger.warning(message);
    return;
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
  final connect = await service.connect(dsn);
  if (connect.isError()) {
    AppLogger.severe('connect: ${connect.exceptionOrNull()}');
    return;
  }

  final connId = connect.getOrThrow().id;
  try {
    final result = await service.executeQueryDirectedParams(
      connId,
      sql,
      const [
        DirectedParam(
          value: ParamValueRefCursorOut(),
          direction: ParamDirection.output,
        ),
      ],
    );
    result.fold(
      (ok) {
        AppLogger.info(
          'Oracle ref cursor result sets: ${ok.refCursorResults.length}',
        );
        for (final (index, cursor) in ok.refCursorResults.indexed) {
          AppLogger.info(
            '  cursor[$index]: rows=${cursor.rowCount}, '
            'columns=${cursor.columns.join(', ')}',
          );
        }
      },
      (error) => AppLogger.severe(
        'ref cursor call failed: $error. Confirm this is an Oracle DSN and '
        'the call text contains one ? marker per ParamValueRefCursorOut.',
      ),
    );
  } finally {
    await service.disconnect(connId);
  }
}

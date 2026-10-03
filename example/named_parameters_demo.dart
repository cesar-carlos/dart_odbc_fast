// Repeated SQL: prepare once, bind new values, close once.
// Named syntax is convenient; typed positional binds avoid rebuilding a map.
// Run: dart run example/named_parameters_demo.dart
// Optional: ODBC_PREPARED_ITERATIONS (default 100).

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() =>
    withExampleConnection((locator, service, connection) async {
      final iterations = positiveExampleEnvInt('ODBC_PREPARED_ITERATIONS', 100);
      final named = (await service.executeQueryNamed(
        connection.id,
        'SELECT CAST(@id AS INTEGER) AS first_id, CAST(@id AS INTEGER) AS '
        'repeated_id',
        const {'id': 7},
      ))
          .getOrThrow();
      reportExampleProgress(
        'Repeated named placeholder: rows=${named.rowCount}',
      );
      final statement = (await service.prepare(
        connection.id,
        'SELECT CAST(? AS INTEGER) AS id',
      ))
          .getOrThrow();
      final stopwatch = Stopwatch()..start();
      var rows = 0;
      try {
        for (var id = 0; id < iterations; id++) {
          final result = (await service.executePreparedParamValues(
            connection.id,
            statement,
            [ParamValueInt32(id)],
            const StatementOptions(fetchSize: 1000),
          ))
              .getOrThrow();
          rows += result.rowCount;
        }
      } finally {
        stopwatch.stop();
        reportExampleCleanup(
          await service.closeStatement(connection.id, statement),
          'closeStatement',
        );
      }
      reportExampleProgress('prepared once; executions=$iterations rows=$rows '
          'elapsedUs=${stopwatch.elapsedMicroseconds}');
      // Named reuse: prepareNamed / executePreparedNamed, with the same
      // lifecycle.
      // Do not prepare inside the execution loop.
    });

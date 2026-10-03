// One indexed reader per result, without allocating a map for every row.
// Run: dart run example/query_result_access_demo.dart
// Optional: ODBC_READER_QUERY returning id and score. For large results use
// streaming_demo.dart and create a reader for each batch.

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() =>
    withExampleConnection((locator, service, connection) async {
      final result = (await locator.queryService.executeQueryFor(
        connection,
        Platform.environment['ODBC_READER_QUERY'] ??
            'SELECT 1 AS id, CAST(42.5 AS FLOAT) AS score '
                'UNION ALL SELECT 2, CAST(NULL AS FLOAT)',
      ))
          .getOrThrow();
      final reader = result.reader(); // Column names are fixed at creation.
      num total = 0;
      var values = 0;
      for (var row = 0; row < result.rowCount; row++) {
        final score = reader.cellAs<num>(row, 'score', ignoreCase: true);
        if (score == null) continue;
        total += score;
        values++;
      }
      reportExampleProgress('rows=${result.rowCount} scores=$values sum=$total '
          'firstId=${reader.scalar<int>('id', ignoreCase: true)}');
      // Helpers preserve nulls and types. No rowsAsMaps/columnValues
      // allocation.
    });

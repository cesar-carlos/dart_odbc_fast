// Buffered numeric analytics. Large scans: stream_query_columnar_demo.dart.
// Run: dart run example/typed_columnar_demo.dart
// Optional: ODBC_COLUMNAR_QUERY returning a numeric score column.

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

const defaultColumnarQuery =
    'SELECT CAST(1 AS INTEGER) AS id, CAST(42.5 AS FLOAT) AS score '
    'UNION ALL SELECT 2, CAST(NULL AS FLOAT)';

Future<void> main() => withExampleConnection(
      (locator, service, connection) async {
        final result = (await service.executeQueryColumnarParamValues(
          connection.id,
          Platform.environment['ODBC_COLUMNAR_QUERY'] ?? defaultColumnarQuery,
          params: const <ParamValue>[],
        ))
            .getOrThrow();
        final total = sumNonNullScores(result);
        reportExampleProgress(
          'rows=${result.rowCount} columns=${result.columnCount} '
          'scoreSum=$total',
        );
      },
      profile: OdbcUsageProfile.balancedServer,
    );

/// Resolves a column once and consumes typed arrays without row maps.
/// Decimal columns may be string-backed; request FLOAT/DOUBLE for this path.
num sumNonNullScores(TypedColumnarResult result) {
  final column = result.columns.firstWhere(
    (column) => column.name.toLowerCase() == 'score',
    orElse: () => throw StateError('Expected a numeric score column.'),
  );
  switch (column) {
    case TypedColumnFloat64():
      var total = 0.0;
      final values = column.values;
      for (var row = 0; row < values.length; row++) {
        if (!column.isNullAt(row)) total += values[row];
      }
      return total;
    case TypedColumnInt32():
      var total = 0;
      final values = column.values;
      for (var row = 0; row < values.length; row++) {
        if (!column.isNullAt(row)) total += values[row];
      }
      return total;
    case TypedColumnInt64():
      var total = 0;
      final values = column.values;
      for (var row = 0; row < values.length; row++) {
        if (!column.isNullAt(row)) total += values[row];
      }
      return total;
    case TypedColumnObject():
      throw StateError('Expected FLOAT/DOUBLE or integer score values.');
  }
}

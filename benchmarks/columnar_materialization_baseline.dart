// Historical implementation from 9a6e367 for paired benchmarks only.
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/infrastructure/native/protocol/lazy_string.dart';

QueryResult fromTypedColumnar(TypedColumnarResult result) {
  final n = result.rowCount;
  final columnNames = result.columns.map((c) => c.name).toList(growable: false);
  if (n == 0) {
    return QueryResult(
      columns: columnNames,
      rows: const [],
      rowCount: 0,
    );
  }

  final rows = List<List<dynamic>>.generate(
    n,
    (_) => List<dynamic>.filled(result.columnCount, null),
  );

  for (var c = 0; c < result.columns.length; c++) {
    final col = result.columns[c];
    for (var r = 0; r < n; r++) {
      if (col.isNullAt(r)) {
        rows[r][c] = null;
        continue;
      }
      rows[r][c] = switch (col) {
        TypedColumnInt32(:final values) => values[r],
        TypedColumnInt64(:final values) => values[r],
        TypedColumnFloat64(:final values) => values[r],
        TypedColumnObject(:final kind, :final values) => switch (kind) {
            TypedColumnKind.string => _unwrapStringLike(values[r]),
            _ => values[r],
          },
      };
    }
  }

  return QueryResult(columns: columnNames, rows: rows, rowCount: n);
}

Object? _unwrapStringLike(Object? value) {
  if (value == null || value is String || value is LazyString) {
    return value;
  }
  if (value is int || value is double) {
    return value;
  }
  if (value is bool || value is DateTime || value is List<int>) {
    return value;
  }
  return value.toString();
}

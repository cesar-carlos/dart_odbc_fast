import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/infrastructure/native/protocol/lazy_string.dart';

/// Converts a row-major [QueryResult] into a column-major
/// [TypedColumnarResult] by inferring the column kind from the first
/// non-null cell in each column.
TypedColumnarResult toTypedColumnar(QueryResult result) {
  final n = result.rows.length;
  final columns = <TypedColumn>[];

  for (var c = 0; c < result.columns.length; c++) {
    final name = result.columns[c];
    final kind = _inferKind(result.rows, c);
    columns.add(_buildColumn(name, kind, result.rows, c, n));
  }

  return TypedColumnarResult(columns: columns, rowCount: n);
}

/// Materializes a row-major [QueryResult] from a [TypedColumnarResult].
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

/// Converts a row-major buffer into typed columns using wire ODBC
/// discriminants when provided (avoids a [QueryResult] intermediate).
TypedColumnarResult toTypedColumnarFromWire({
  required List<String> columnNames,
  required List<int> odbcDiscriminants,
  required List<List<dynamic>> rows,
}) {
  final n = rows.length;
  final columns = <TypedColumn>[];
  for (var c = 0; c < columnNames.length; c++) {
    final kind = c < odbcDiscriminants.length
        ? _kindFromDiscriminant(odbcDiscriminants[c], rows, c)
        : _inferKind(rows, c);
    columns.add(_buildColumn(columnNames[c], kind, rows, c, n));
  }
  return TypedColumnarResult(columns: columns, rowCount: n);
}

TypedColumnKind _kindFromDiscriminant(
  int discriminant,
  List<List<dynamic>> rows,
  int col,
) {
  // Keep in sync with OdbcType discriminants / columnar typed kinds.
  switch (discriminant) {
    case 2:
      return TypedColumnKind.int32;
    case 3:
      return TypedColumnKind.int64;
    case 7:
      return TypedColumnKind.bytes;
    case 13:
      return TypedColumnKind.bool_;
    case 14:
    case 15:
      return TypedColumnKind.float64;
    case 4:
    case 18:
      return TypedColumnKind.decimal;
    case 5:
    case 6:
    case 9:
    case 10:
    case 11:
      return TypedColumnKind.dateTime;
    case 1:
    case 8:
      return TypedColumnKind.string;
    default:
      return _inferKind(rows, col);
  }
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

TypedColumnKind _inferKind(List<List<dynamic>> rows, int col) {
  for (final row in rows) {
    final v = row[col];
    if (v == null) continue;
    if (v is int) {
      return _allFitInt32(rows, col)
          ? TypedColumnKind.int32
          : TypedColumnKind.int64;
    }
    if (v is double) return TypedColumnKind.float64;
    if (v is bool) return TypedColumnKind.bool_;
    if (v is String || v is LazyString) return TypedColumnKind.string;
    if (v is List<int>) return TypedColumnKind.bytes;
    if (v is DateTime) return TypedColumnKind.dateTime;
    return TypedColumnKind.unknown;
  }
  return TypedColumnKind.unknown;
}

bool _allFitInt32(List<List<dynamic>> rows, int col) {
  const min = -2147483648;
  const max = 2147483647;
  for (final row in rows) {
    final v = row[col];
    if (v == null) continue;
    if (v is! int) return false;
    if (v < min || v > max) return false;
  }
  return true;
}

TypedColumn _buildColumn(
  String name,
  TypedColumnKind kind,
  List<List<dynamic>> rows,
  int col,
  int n,
) {
  switch (kind) {
    case TypedColumnKind.int32:
      final values = Int32List(n);
      final bitmap = Uint8List((n + 7) >> 3);
      for (var i = 0; i < n; i++) {
        final v = rows[i][col];
        if (v == null) {
          _setBit(bitmap, i);
          continue;
        }
        values[i] = v as int;
      }
      return TypedColumnInt32(name: name, values: values, nullBitmap: bitmap);
    case TypedColumnKind.int64:
      final values = Int64List(n);
      final bitmap = Uint8List((n + 7) >> 3);
      for (var i = 0; i < n; i++) {
        final v = rows[i][col];
        if (v == null) {
          _setBit(bitmap, i);
          continue;
        }
        values[i] = v as int;
      }
      return TypedColumnInt64(name: name, values: values, nullBitmap: bitmap);
    case TypedColumnKind.float64:
      final values = Float64List(n);
      final bitmap = Uint8List((n + 7) >> 3);
      for (var i = 0; i < n; i++) {
        final v = rows[i][col];
        if (v == null) {
          _setBit(bitmap, i);
          continue;
        }
        if (v is double) {
          values[i] = v;
        } else if (v is num) {
          values[i] = v.toDouble();
        } else {
          values[i] = double.parse(v.toString());
        }
      }
      return TypedColumnFloat64(
        name: name,
        values: values,
        nullBitmap: bitmap,
      );
    case TypedColumnKind.bool_:
      return TypedColumnObject<bool>(
        name: name,
        kind: kind,
        values: List<bool?>.generate(n, (i) {
          final v = rows[i][col];
          if (v == null) {
            return null;
          }
          if (v is bool) {
            return v;
          }
          final text = v.toString().trim().toLowerCase();
          if (text == '0' || text == 'false') {
            return false;
          }
          if (text == '1' || text == 'true') {
            return true;
          }
          throw FormatException('Cannot coerce bool from "$v"');
        }),
      );
    case TypedColumnKind.string:
      final hasLazy = rows.any((row) => row[col] is LazyString);
      if (hasLazy) {
        return TypedColumnObject<Object>(
          name: name,
          kind: kind,
          values: List<Object?>.generate(n, (i) => rows[i][col]),
        );
      }
      return TypedColumnObject<String>(
        name: name,
        kind: kind,
        values: List<String?>.generate(n, (i) => rows[i][col] as String?),
      );
    case TypedColumnKind.bytes:
      return TypedColumnObject<List<int>>(
        name: name,
        kind: kind,
        values: List<List<int>?>.generate(n, (i) => rows[i][col] as List<int>?),
      );
    case TypedColumnKind.dateTime:
      return TypedColumnObject<DateTime>(
        name: name,
        kind: kind,
        values: List<DateTime?>.generate(n, (i) => rows[i][col] as DateTime?),
      );
    case TypedColumnKind.decimal:
    case TypedColumnKind.unknown:
      return TypedColumnObject<Object>(
        name: name,
        kind: kind,
        values: List<Object?>.generate(n, (i) => rows[i][col] as Object?),
      );
  }
}

void _setBit(Uint8List bitmap, int row) {
  final byteIndex = row >> 3;
  final bit = 1 << (row & 0x7);
  bitmap[byteIndex] |= bit;
}

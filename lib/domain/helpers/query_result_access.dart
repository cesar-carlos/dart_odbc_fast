import 'package:odbc_fast/domain/entities/query_result.dart';

/// Low-risk typed accessors for [QueryResult] row/column navigation.
///
/// These helpers do not change the underlying `List<dynamic>` storage; they
/// only reduce boilerplate when reading scalar values from small result sets.
extension QueryResultAccess on QueryResult {
  /// Returns the zero-based index of [column], or `null` when absent.
  ///
  /// When [ignoreCase] is true, matching is case-insensitive.
  int? columnIndex(String column, {bool ignoreCase = false}) {
    if (ignoreCase) {
      final lower = column.toLowerCase();
      for (var i = 0; i < columns.length; i++) {
        if (columns[i].toLowerCase() == lower) {
          return i;
        }
      }
      return null;
    }
    final idx = columns.indexOf(column);
    return idx < 0 ? null : idx;
  }

  /// Returns the value at [row] / [column], or `null` when out of range.
  Object? cell(int row, String column, {bool ignoreCase = false}) {
    final idx = columnIndex(column, ignoreCase: ignoreCase);
    if (idx == null || row < 0 || row >= rows.length) {
      return null;
    }
    final values = rows[row];
    if (idx >= values.length) {
      return null;
    }
    return values[idx];
  }

  /// Returns row [row] as a name → value map aligned with [columns].
  Map<String, Object?> rowAsMap(int row) {
    if (row < 0 || row >= rows.length) {
      return const <String, Object?>{};
    }
    final values = rows[row];
    final out = <String, Object?>{};
    for (var i = 0; i < columns.length; i++) {
      out[columns[i]] = i < values.length ? values[i] : null;
    }
    return out;
  }

  /// Returns all values for [column] as a typed list.
  ///
  /// Values that are not assignable to [T] are skipped. When [includeNulls]
  /// is true, `null` entries are preserved as `null` in the result.
  List<T?> columnValues<T>(
    String column, {
    bool ignoreCase = false,
    bool includeNulls = true,
  }) {
    final idx = columnIndex(column, ignoreCase: ignoreCase);
    if (idx == null) {
      return const [];
    }
    final out = <T?>[];
    for (final row in rows) {
      if (idx >= row.length) {
        if (includeNulls) {
          out.add(null);
        }
        continue;
      }
      final value = row[idx];
      if (value == null) {
        if (includeNulls) {
          out.add(null);
        }
        continue;
      }
      if (value is T) {
        out.add(value);
      }
    }
    return out;
  }

  /// Returns the first row's value for [column], or `null` when empty.
  T? firstValue<T>(String column, {bool ignoreCase = false}) {
    final value = cell(0, column, ignoreCase: ignoreCase);
    return value is T ? value : null;
  }

  /// Returns true when [column] exists in [columns].
  bool hasColumn(String column, {bool ignoreCase = false}) =>
      columnIndex(column, ignoreCase: ignoreCase) != null;

  /// Returns the value at [row] / [column] cast to [T], or `null` when absent
  /// or not assignable to [T].
  T? cellAs<T>(int row, String column, {bool ignoreCase = false}) {
    final value = cell(row, column, ignoreCase: ignoreCase);
    return value is T ? value : null;
  }

  /// All rows as name → value maps aligned with [columns].
  List<Map<String, Object?>> get rowsAsMaps =>
      List<Map<String, Object?>>.generate(rows.length, rowAsMap);

  /// First row as a map, or `null` when [isEmpty].
  Map<String, Object?>? get firstRowOrNull => isEmpty ? null : rowAsMap(0);

  /// Single scalar from the first row for [column], or `null` when empty or
  /// not assignable to [T]. Alias for [firstValue].
  T? scalar<T>(String column, {bool ignoreCase = false}) =>
      firstValue<T>(column, ignoreCase: ignoreCase);
}

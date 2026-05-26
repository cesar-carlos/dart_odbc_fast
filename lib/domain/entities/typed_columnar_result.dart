import 'dart:typed_data';

/// Categorical type tag for a typed column. Mirrors the major ODBC type
/// families exposed across the binary protocol; the wire-level
/// discriminant is `protocol/odbc_type.dart` and is decoded once when the
/// column is built.
enum TypedColumnKind {
  int32,
  int64,
  float64,
  bool_,
  string,
  bytes,
  dateTime,
  decimal,
  unknown,
}

/// A single column of a [TypedColumnarResult] with eagerly decoded
/// values stored in a type-specific list.
///
/// When the underlying ODBC type is numeric, the values are stored in a
/// `TypedData` view (`Int32List`, `Int64List`, `Float64List`) so
/// downstream numeric pipelines avoid `int`/`double` boxing on every
/// row. Strings, bytes, and date/time stay in `List<T?>` because
/// `TypedData` cannot hold them.
sealed class TypedColumn {
  const TypedColumn({required this.name, required this.kind});

  /// Column name from `ColumnMetadata.name`.
  final String name;

  /// Logical type of the column. See [TypedColumnKind].
  final TypedColumnKind kind;

  /// Number of rows in this column (matches the parent
  /// [TypedColumnarResult.rowCount]).
  int get length;

  /// Whether row [row] is NULL.
  bool isNullAt(int row);
}

/// Column of `int32` values backed by an `Int32List`. The companion
/// [nullBitmap] flags rows where the cell was SQL `NULL`; the slot in
/// [values] holds `0` for nulls (the bitmap is authoritative).
final class TypedColumnInt32 extends TypedColumn {
  TypedColumnInt32({
    required super.name,
    required this.values,
    required this.nullBitmap,
  }) : super(kind: TypedColumnKind.int32);

  final Int32List values;
  final Uint8List nullBitmap;

  @override
  int get length => values.length;

  @override
  bool isNullAt(int row) => _bitmapHas(nullBitmap, row);
}

/// Column of `int64` values backed by an `Int64List`.
final class TypedColumnInt64 extends TypedColumn {
  TypedColumnInt64({
    required super.name,
    required this.values,
    required this.nullBitmap,
  }) : super(kind: TypedColumnKind.int64);

  final Int64List values;
  final Uint8List nullBitmap;

  @override
  int get length => values.length;

  @override
  bool isNullAt(int row) => _bitmapHas(nullBitmap, row);
}

/// Column of double-precision floats backed by a `Float64List`.
final class TypedColumnFloat64 extends TypedColumn {
  TypedColumnFloat64({
    required super.name,
    required this.values,
    required this.nullBitmap,
  }) : super(kind: TypedColumnKind.float64);

  final Float64List values;
  final Uint8List nullBitmap;

  @override
  int get length => values.length;

  @override
  bool isNullAt(int row) => _bitmapHas(nullBitmap, row);
}

/// Generic nullable-list column for types that don't fit a `TypedData`
/// view (string, bytes, dateTime, decimal, unknown).
final class TypedColumnObject<T> extends TypedColumn {
  TypedColumnObject({
    required super.name,
    required super.kind,
    required this.values,
  });

  final List<T?> values;

  @override
  int get length => values.length;

  @override
  bool isNullAt(int row) => values[row] == null;
}

/// Result-set view that exposes data **column-major** with typed primitive
/// arrays for numeric columns. Sister representation to the row-major
/// `QueryResult`; both are produced from the same wire payload, callers
/// pick whichever fits their access pattern.
///
/// Trade-offs vs `QueryResult`:
///
/// - **Faster numeric reads**: avoids `dynamic` boxing on every cell;
///   `Int32List` is a view over a contiguous byte buffer.
/// - **Worse for row-at-a-time access**: building a single row requires
///   visiting one cell per column.
/// - **Memory**: numeric columns share the protocol byte buffer when
///   possible; non-numeric columns hold per-row `Object?` references
///   (no different from `QueryResult`).
///
/// Usage:
///
/// ```dart
/// final r = await service.executeQueryColumnar(
///   connId,
///   'SELECT id, score FROM stats',
/// );
/// r.fold(
///   (typed) {
///     final ids = typed.column<TypedColumnInt32>('id').values;
///     final scores = typed.column<TypedColumnFloat64>('score').values;
///     for (var i = 0; i < ids.length; i++) {
///       sum += ids[i] * scores[i];
///     }
///   },
///   (e) => print('error: $e'),
/// );
/// ```
class TypedColumnarResult {
  TypedColumnarResult({
    required this.columns,
    required this.rowCount,
  });

  /// Columns in declaration order (matches `QueryResult.columns`).
  final List<TypedColumn> columns;

  /// Number of rows shared by every column.
  final int rowCount;

  /// Looks up a column by name and returns it cast to the expected
  /// concrete type [T] (`TypedColumnInt32`, `TypedColumnFloat64`, etc.).
  /// Throws [StateError] when the name is unknown or the type doesn't
  /// match — fail-fast prevents silently returning the wrong shape.
  T column<T extends TypedColumn>(String name) {
    final col = columns.firstWhere(
      (c) => c.name == name,
      orElse: () =>
          throw StateError('TypedColumnarResult: column "$name" not found'),
    );
    if (col is! T) {
      throw StateError(
        'TypedColumnarResult: column "$name" is ${col.runtimeType}, '
        'requested $T',
      );
    }
    return col;
  }

  /// Number of columns. O(1).
  int get columnCount => columns.length;
}

bool _bitmapHas(Uint8List bitmap, int row) {
  final byteIndex = row >> 3;
  if (byteIndex >= bitmap.length) return false;
  final bit = 1 << (row & 0x7);
  return (bitmap[byteIndex] & bit) != 0;
}

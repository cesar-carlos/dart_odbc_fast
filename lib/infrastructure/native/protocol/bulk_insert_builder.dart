import 'dart:convert';
import 'dart:typed_data';

const int _tagI32 = 0;
const int _tagI64 = 1;
const int _tagText = 2;
const int _tagDecimal = 3;
const int _tagBinary = 4;
const int _tagTimestamp = 5;

int _nullBitmapSize(int rowCount) => (rowCount / 8).ceil();

void _setNullAt(List<int> bitmap, int row) {
  final byteIndex = row ~/ 8;
  if (byteIndex >= bitmap.length) return;
  bitmap[byteIndex] |= 1 << (row % 8);
}

List<int> _u32Le(int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.little);
  return b.buffer.asUint8List(0, 4).toList();
}

List<int> _i32Le(int v) {
  final b = ByteData(4)..setInt32(0, v, Endian.little);
  return b.buffer.asUint8List(0, 4).toList();
}

List<int> _i64Le(int v) {
  final b = ByteData(8)..setInt64(0, v, Endian.little);
  return b.buffer.asUint8List(0, 8).toList();
}

List<int> _u16Le(int v) {
  final b = ByteData(2)..setUint16(0, v, Endian.little);
  return b.buffer.asUint8List(0, 2).toList();
}

List<int> _i16Le(int v) {
  final b = ByteData(2)..setInt16(0, v, Endian.little);
  return b.buffer.asUint8List(0, 2).toList();
}

/// Column data types for bulk insert operations.
enum BulkColumnType {
  /// 32-bit integer.
  i32(_tagI32),

  /// 64-bit integer.
  i64(_tagI64),

  /// Text/string data.
  text(_tagText),

  /// Decimal/numeric data.
  decimal(_tagDecimal),

  /// Binary data.
  binary(_tagBinary),

  /// Timestamp/datetime data.
  timestamp(_tagTimestamp);

  /// Creates a [BulkColumnType] with the given tag.
  const BulkColumnType(this.tag);

  /// The numeric tag used in the binary protocol.
  final int tag;
}

/// Specification for a column in a bulk insert operation.
class BulkColumnSpec {
  /// Creates a new [BulkColumnSpec] instance.
  ///
  /// The [name] is the column name.
  /// The [colType] specifies the data type.
  /// The [nullable] flag indicates if the column can contain NULL values.
  /// The [maxLen] specifies the maximum length for variable-length types.
  BulkColumnSpec({
    required this.name,
    required this.colType,
    this.nullable = false,
    this.maxLen = 0,
  });

  /// The column name.
  final String name;

  /// The column data type.
  final BulkColumnType colType;

  /// Whether the column can contain NULL values.
  final bool nullable;

  /// Maximum length for variable-length types (0 = unlimited).
  final int maxLen;
}

/// Represents a timestamp value for bulk insert operations.
class BulkTimestamp {
  /// Creates a new [BulkTimestamp] instance.
  const BulkTimestamp({
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
    this.fraction = 0,
  });

  /// The year (e.g., 2024).
  final int year;

  /// The month (1-12).
  final int month;

  /// The day of month (1-31).
  final int day;

  /// The hour (0-23).
  final int hour;

  /// The minute (0-59).
  final int minute;

  /// The second (0-59).
  final int second;

  /// Fractional seconds in nanoseconds.
  final int fraction;

  /// Creates a [BulkTimestamp] from a [DateTime] instance.
  // ignore: prefer_constructors_over_static_methods
  static BulkTimestamp fromDateTime(DateTime dt) {
    return BulkTimestamp(
      year: dt.year,
      month: dt.month,
      day: dt.day,
      hour: dt.hour,
      minute: dt.minute,
      second: dt.second,
      fraction: dt.millisecond * 1000000 + dt.microsecond,
    );
  }
}

/// Builder for creating bulk insert data buffers.
///
/// Provides a fluent API to define table structure, columns, and rows
/// for efficient bulk insert operations.
///
/// Example:
/// ```dart
/// final builder = BulkInsertBuilder()
///   ..table('users')
///   ..addColumn('id', BulkColumnType.i32)
///   ..addColumn('name', BulkColumnType.text, maxLen: 100)
///   ..addRow([1, 'Alice'])
///   ..addRow([2, 'Bob']);
/// final buffer = builder.build();
/// ```
class BulkInsertBuilder {
  /// Creates a new [BulkInsertBuilder] instance.
  BulkInsertBuilder();

  String _table = '';
  final List<BulkColumnSpec> _columns = [];
  final List<List<dynamic>> _rows = [];

  /// Sets the target table name for the bulk insert.
  ///
  /// The [name] is the table name where rows will be inserted.
  /// Returns this builder for method chaining.
  BulkInsertBuilder table(String name) {
    _table = name;
    // Builder pattern requires returning this for method chaining.
    // ignore: avoid_returning_this
    return this;
  }

  /// Adds a column definition to the bulk insert.
  ///
  /// The [name] is the column name.
  /// The [colType] specifies the data type.
  /// The [nullable] flag indicates if the column can contain NULL values.
  /// The [maxLen] specifies the maximum length for variable-length types.
  ///
  /// Returns this builder for method chaining.
  BulkInsertBuilder addColumn(
    String name,
    BulkColumnType colType, {
    bool nullable = false,
    int maxLen = 0,
  }) {
    _columns.add(
      BulkColumnSpec(
        name: name,
        colType: colType,
        nullable: nullable,
        maxLen: maxLen,
      ),
    );
    // Builder pattern requires returning this for method chaining.
    // ignore: avoid_returning_this
    return this;
  }

  /// Adds a row of data to the bulk insert.
  ///
  /// The [values] list must contain values in the same order as columns
  /// were added, and must match the column count.
  ///
  /// Returns this builder for method chaining.
  /// Throws [StateError] if columns haven't been added yet.
  /// Throws [ArgumentError] if the row length doesn't match column count.
  BulkInsertBuilder addRow(List<dynamic> values) {
    if (_columns.isEmpty) {
      throw StateError('Add columns before rows');
    }
    if (values.length != _columns.length) {
      throw ArgumentError(
        'Row length ${values.length} != column count ${_columns.length}',
      );
    }
    _rows.add(List<dynamic>.from(values));
    // Builder pattern requires returning this for method chaining.
    // ignore: avoid_returning_this
    return this;
  }

  /// Gets the table name.
  String get tableName => _table;

  /// Gets the list of column names in the order they were added.
  List<String> get columnNames => _columns.map((c) => c.name).toList();

  /// Gets the number of rows added to the builder.
  int get rowCount => _rows.length;

  /// Builds the binary data buffer for bulk insert.
  ///
  /// Validates that table name, columns, and at least one row are present.
  /// Returns a [Uint8List] containing the serialized bulk insert data.
  ///
  /// Throws [StateError] if table name is empty, no columns are defined,
  /// or no rows have been added.
  Uint8List build() {
    if (_table.isEmpty) {
      throw StateError('Table name required');
    }
    if (_columns.isEmpty) {
      throw StateError('At least one column required');
    }
    if (_rows.isEmpty) {
      throw StateError('At least one row required');
    }

    final out = <int>[];
    final tableBytes = utf8.encode(_table);
    out
      ..addAll(_u32Le(tableBytes.length))
      ..addAll(tableBytes)
      ..addAll(_u32Le(_columns.length));

    for (final spec in _columns) {
      final nameBytes = utf8.encode(spec.name);
      out
        ..addAll(_u32Le(nameBytes.length))
        ..addAll(nameBytes)
        ..add(spec.tag)
        ..add(spec.nullable ? 1 : 0)
        ..addAll(_u32Le(spec.maxLen));
    }

    final rowCount = _rows.length;
    out.addAll(_u32Le(rowCount));

    for (var c = 0; c < _columns.length; c++) {
      final spec = _columns[c];
      _serializeColumn(out, spec, c, rowCount);
    }

    return Uint8List.fromList(out);
  }

  void _serializeColumn(
    List<int> out,
    BulkColumnSpec spec,
    int colIndex,
    int rowCount,
  ) {
    final maxLen = spec.maxLen > 0 ? spec.maxLen : 1;
    List<int>? nullBitmap;
    if (spec.nullable) {
      nullBitmap = List.filled(_nullBitmapSize(rowCount), 0);
    }

    switch (spec.colType) {
      case BulkColumnType.i32:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            final v = _rows[r][colIndex];
            if (v == null) _setNullAt(nullBitmap, r);
          }
          out.addAll(nullBitmap);
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _rows[r][colIndex];
          final i = v == null ? 0 : (v is int ? v : int.tryParse('$v') ?? 0);
          out.addAll(_i32Le(i));
        }
      case BulkColumnType.i64:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            if (_rows[r][colIndex] == null) _setNullAt(nullBitmap, r);
          }
          out.addAll(nullBitmap);
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _rows[r][colIndex];
          final i = v == null ? 0 : (v is int ? v : int.tryParse('$v') ?? 0);
          out.addAll(_i64Le(i));
        }
      case BulkColumnType.text:
      case BulkColumnType.decimal:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            if (_rows[r][colIndex] == null) _setNullAt(nullBitmap, r);
          }
          out.addAll(nullBitmap);
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _rows[r][colIndex];
          List<int> raw;
          if (v == null) {
            raw = <int>[];
          } else if (v is String) {
            raw = utf8.encode(v);
          } else {
            raw = utf8.encode('$v');
          }
          final len = raw.length.clamp(0, maxLen);
          out.addAll(raw.take(len));
          for (var i = len; i < maxLen; i++) {
            out.add(0);
          }
        }
      case BulkColumnType.binary:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            if (_rows[r][colIndex] == null) _setNullAt(nullBitmap, r);
          }
          out.addAll(nullBitmap);
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _rows[r][colIndex];
          List<int> raw;
          if (v == null) {
            raw = <int>[];
          } else if (v is Uint8List) {
            raw = v.toList();
          } else if (v is List<int>) {
            raw = v;
          } else {
            raw = <int>[];
          }
          final len = raw.length.clamp(0, maxLen);
          out.addAll(raw.take(len));
          for (var i = len; i < maxLen; i++) {
            out.add(0);
          }
        }
      case BulkColumnType.timestamp:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            if (_rows[r][colIndex] == null) _setNullAt(nullBitmap, r);
          }
          out.addAll(nullBitmap);
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _rows[r][colIndex];
          BulkTimestamp t;
          if (v == null) {
            t = const BulkTimestamp(
              year: 0,
              month: 0,
              day: 0,
              hour: 0,
              minute: 0,
              second: 0,
            );
          } else if (v is DateTime) {
            t = BulkTimestamp.fromDateTime(v);
          } else if (v is BulkTimestamp) {
            t = v;
          } else {
            t = const BulkTimestamp(
              year: 0,
              month: 0,
              day: 0,
              hour: 0,
              minute: 0,
              second: 0,
            );
          }
          out
            ..addAll(_i16Le(t.year))
            ..addAll(_u16Le(t.month))
            ..addAll(_u16Le(t.day))
            ..addAll(_u16Le(t.hour))
            ..addAll(_u16Le(t.minute))
            ..addAll(_u16Le(t.second))
            ..addAll(_u32Le(t.fraction));
        }
    }
  }
}

extension on BulkColumnSpec {
  int get tag => colType.tag;
}

import 'dart:convert';
import 'dart:typed_data';

const int _tagI32 = 0;
const int _tagI64 = 1;
const int _tagText = 2;
const int _tagDecimal = 3;
const int _tagBinary = 4;
const int _tagTimestamp = 5;
const Endian _littleEndian = Endian.little;
const List<int> _bulkPayloadV2Magic = [0x42, 0x4C, 0x4B, 0x32]; // BLK2
const int _bulkPayloadV2Version = 2;
const int _bulkPayloadV2Flags = 0;

int _nullBitmapSize(int rowCount) => (rowCount / 8).ceil();

void _setNullAt(List<int> bitmap, int row) {
  final byteIndex = row ~/ 8;
  // Callers always allocate bitmap using _nullBitmapSize(rowCount),
  // so byteIndex is guaranteed to be within bounds for valid row values.
  final bitMask = 1 << (row % 8);
  bitmap[byteIndex] |= bitMask;
}

Never _throwNullabilityError(String columnName, int rowNumber) {
  throw StateError(
    'Column "$columnName" is non-nullable but contains null '
    'at row $rowNumber. '
    'Use nullable: true for columns that should accept null.',
  );
}

void _validateTextColumn(String value, BulkColumnSpec spec, int rowNumber) {
  // maxLen is defined in bytes (wire format is UTF-8; legacy path pads to
  // maxLen bytes). Only encode when a limit is actually set.
  if (spec.maxLen > 0) {
    final utf8Bytes = utf8.encode(value);
    if (utf8Bytes.length > spec.maxLen) {
      throw ArgumentError(
        'Column "${spec.name}" UTF-8 encoding exceeds max length '
        '${spec.maxLen} (got ${utf8Bytes.length} bytes) at row $rowNumber.',
      );
    }
  }
}

void _validateBinaryColumn(
  List<int> value,
  BulkColumnSpec spec,
  int rowNumber,
) {
  if (spec.maxLen > 0 && value.length > spec.maxLen) {
    throw ArgumentError(
      'Column "${spec.name}" exceeds max length ${spec.maxLen} '
      '(got ${value.length} bytes) at row $rowNumber.',
    );
  }
}

void _validateValueForColumn(
  dynamic value,
  BulkColumnSpec spec,
  int rowNumber,
) {
  if (value == null) {
    if (spec.nullable) {
      return;
    }
    _throwNullabilityError(spec.name, rowNumber);
  }

  switch (spec.colType) {
    case BulkColumnType.i32:
      if (value is! int || value < -0x80000000 || value > 0x7FFFFFFF) {
        throw ArgumentError(
          'Column "${spec.name}" expects i32 value but got $value '
          '(${value.runtimeType}) at row $rowNumber.',
        );
      }
    case BulkColumnType.i64:
      if (value is! int) {
        throw ArgumentError(
          'Column "${spec.name}" expects i64 value but got $value '
          '(${value.runtimeType}) at row $rowNumber.',
        );
      }
    case BulkColumnType.text:
      if (value is! String) {
        throw ArgumentError(
          'Column "${spec.name}" expects text value but got $value '
          '(${value.runtimeType}) at row $rowNumber.',
        );
      }
      _validateTextColumn(value, spec, rowNumber);
    case BulkColumnType.decimal:
      if (value is! String && value is! num) {
        throw ArgumentError(
          'Column "${spec.name}" expects decimal (num/string) but got $value '
          '(${value.runtimeType}) at row $rowNumber.',
        );
      }
      _validateTextColumn('$value', spec, rowNumber);
    case BulkColumnType.binary:
      if (value is! List<int>) {
        throw ArgumentError(
          'Column "${spec.name}" expects binary data but got $value '
          '(${value.runtimeType}) at row $rowNumber.',
        );
      }
      _validateBinaryColumn(value, spec, rowNumber);
    case BulkColumnType.timestamp:
      if (value is! DateTime && value is! BulkTimestamp) {
        throw ArgumentError(
          'Column "${spec.name}" expects timestamp (DateTime/BulkTimestamp) '
          'but got $value (${value.runtimeType}) at row $rowNumber.',
        );
      }
  }
}

/// Bulk insert wire payload version.
enum BulkPayloadVersion {
  /// Legacy fixed-width wire format without a magic header.
  legacy,

  /// Versioned wire format that stores variable-width cell lengths.
  v2,
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
  // Reason: fromDateTime is the established bulk wire helper;
  // AUDIT-DART-2026-06, remove when BulkTimestamp gains a constructor alias.
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

/// Phase-1 cache for a single [Uint8List] bulk payload allocation.
final class _BulkEncodeCache {
  _BulkEncodeCache({
    required this.totalBytes,
    required this.tableBytes,
    required this.columnNameBytes,
    required this.v2VariableCells,
  });

  final int totalBytes;
  final Uint8List tableBytes;
  final List<Uint8List> columnNameBytes;

  /// Cached UTF-8/binary cells for v2 variable-length columns; `null` otherwise.
  final List<List<Uint8List>?> v2VariableCells;
}

/// Write cursor for a pre-sized bulk payload buffer.
final class _WriteCursor {
  _WriteCursor(this._out) : _bd = ByteData.sublistView(_out);

  final Uint8List _out;
  final ByteData _bd;
  int offset = 0;

  void writeByte(int v) {
    _out[offset] = v;
    offset++;
  }

  void writeBytes(List<int> bytes) {
    _out.setRange(offset, offset + bytes.length, bytes);
    offset += bytes.length;
  }

  void writeBytesRange(List<int> bytes, int start, int end) {
    _out.setRange(offset, offset + (end - start), bytes, start);
    offset += end - start;
  }

  void writeU16Le(int v) {
    _bd.setUint16(offset, v, _littleEndian);
    offset += 2;
  }

  void writeI16Le(int v) {
    _bd.setInt16(offset, v, _littleEndian);
    offset += 2;
  }

  void writeU32Le(int v) {
    _bd.setUint32(offset, v, _littleEndian);
    offset += 4;
  }

  void writeI32Le(int v) {
    _bd.setInt32(offset, v, _littleEndian);
    offset += 4;
  }

  void writeI64Le(int v) {
    _bd.setInt64(offset, v, _littleEndian);
    offset += 8;
  }

  void writeInt32List(Int32List values) {
    final byteLen = 4 * values.length;
    _out.setRange(
      offset,
      offset + byteLen,
      values.buffer.asUint8List(values.offsetInBytes, byteLen),
    );
    offset += byteLen;
  }

  void writeInt64List(Int64List values) {
    final byteLen = 8 * values.length;
    _out.setRange(
      offset,
      offset + byteLen,
      values.buffer.asUint8List(values.offsetInBytes, byteLen),
    );
    offset += byteLen;
  }
}

/// Column-oriented storage for one bulk column (typed APIs).
sealed class _ColumnarColumnData {
  int get length;
  bool isNullAt(int row);
  dynamic valueAt(int row);
}

final class _ColumnarInt32Data extends _ColumnarColumnData {
  _ColumnarInt32Data(this.values, this.isNull);

  final Int32List values;
  final List<bool>? isNull;

  @override
  int get length => values.length;

  @override
  bool isNullAt(int row) => isNull != null && isNull![row];

  @override
  int valueAt(int row) => values[row];
}

final class _ColumnarInt64Data extends _ColumnarColumnData {
  _ColumnarInt64Data(this.values, this.isNull);

  final Int64List values;
  final List<bool>? isNull;

  @override
  int get length => values.length;

  @override
  bool isNullAt(int row) => isNull != null && isNull![row];

  @override
  int valueAt(int row) => values[row];
}

final class _ColumnarTextData extends _ColumnarColumnData {
  _ColumnarTextData(this.values, this.isNull);

  final List<String> values;
  final List<bool>? isNull;

  @override
  int get length => values.length;

  @override
  bool isNullAt(int row) => isNull != null && isNull![row];

  @override
  String valueAt(int row) => values[row];
}

final class _ColumnarDecimalData extends _ColumnarColumnData {
  _ColumnarDecimalData(this.values, this.isNull);

  final List<String> values;
  final List<bool>? isNull;

  @override
  int get length => values.length;

  @override
  bool isNullAt(int row) => isNull != null && isNull![row];

  @override
  String valueAt(int row) => values[row];
}

final class _ColumnarBinaryData extends _ColumnarColumnData {
  _ColumnarBinaryData(this.values, this.isNull);

  final List<Uint8List> values;
  final List<bool>? isNull;

  @override
  int get length => values.length;

  @override
  bool isNullAt(int row) => isNull != null && isNull![row];

  @override
  Uint8List valueAt(int row) => values[row];
}

final class _ColumnarTimestampData extends _ColumnarColumnData {
  _ColumnarTimestampData(this.values, this.isNull);

  final List<Object> values;
  final List<bool>? isNull;

  @override
  int get length => values.length;

  @override
  bool isNullAt(int row) => isNull != null && isNull![row];

  @override
  Object valueAt(int row) => values[row];
}

void _validateColumnarNullMask(
  String columnName,
  int rowCount,
  List<bool>? isNull, {
  required bool nullable,
}) {
  if (isNull == null) {
    return;
  }
  if (isNull.length != rowCount) {
    throw ArgumentError(
      'Column "$columnName" isNull mask length ${isNull.length} != row count '
      '$rowCount',
    );
  }
  if (!nullable && isNull.any((v) => v)) {
    throw StateError(
      'Column "$columnName" is non-nullable but isNull marks a null row',
    );
  }
}

/// Builder for creating bulk insert data buffers.
///
/// Provides a fluent API to define table structure, columns, and rows
/// for efficient bulk insert operations.
///
/// Rows passed to [addRow] are stored by reference; do not mutate a row list
/// after it is added (wrap with `List.unmodifiable` when the same list instance
/// might be reused elsewhere).
///
/// Row-oriented example:
/// ```dart
/// final builder = BulkInsertBuilder()
///   ..table('users')
///   ..addColumn('id', BulkColumnType.i32)
///   ..addColumn('name', BulkColumnType.text, maxLen: 100)
///   ..addRow([1, 'Alice'])
///   ..addRow([2, 'Bob']);
/// final buffer = builder.build();
/// ```
///
/// Columnar example (avoids per-row `List<dynamic>` and bulk-copies
/// fixed-width primitives):
/// ```dart
/// final builder = BulkInsertBuilder()
///   ..table('users')
///   ..addColumnInt32('id', Int32List.fromList([1, 2]))
///   ..addColumnText('name', ['Alice', 'Bob'], maxLen: 100);
/// final buffer = builder.build();
/// ```
class BulkInsertBuilder {
  /// Creates a new [BulkInsertBuilder] instance.
  BulkInsertBuilder();

  String _table = '';
  final List<BulkColumnSpec> _columns = [];
  final List<List<dynamic>> _rows = [];
  final List<_ColumnarColumnData> _columnarData = [];

  bool get _usesColumnar => _columnarData.isNotEmpty;

  int get _effectiveRowCount =>
      _usesColumnar ? _columnarData.first.length : _rows.length;

  void _ensureRowOrientedApis() {
    if (_usesColumnar) {
      throw StateError(
        'Cannot use addColumn/addRow after columnar addColumn* APIs',
      );
    }
  }

  void _ensureColumnarApis() {
    if (_rows.isNotEmpty) {
      throw StateError('Cannot use columnar addColumn* after addRow');
    }
    if (_columns.isNotEmpty && !_usesColumnar) {
      throw StateError(
        'Cannot mix columnar addColumn* with row-oriented addColumn; '
        'use addRow or restart with addColumnInt32/addColumnInt64/...',
      );
    }
  }

  void _registerColumnarColumn(
    BulkColumnSpec spec,
    _ColumnarColumnData data,
    List<bool>? isNull,
  ) {
    _validateColumnarNullMask(
      spec.name,
      data.length,
      isNull,
      nullable: spec.nullable,
    );
    if (_usesColumnar && data.length != _effectiveRowCount) {
      throw ArgumentError(
        'Column "${spec.name}" row count ${data.length} != existing row count '
        '$_effectiveRowCount',
      );
    }
    if (!spec.nullable) {
      for (var r = 0; r < data.length; r++) {
        if (data.isNullAt(r)) {
          _throwNullabilityError(spec.name, r + 1);
        }
      }
    }
    _columns.add(spec);
    _columnarData.add(data);
  }

  /// Sets the target table name for the bulk insert.
  ///
  /// The [name] is the table name where rows will be inserted.
  /// Returns this builder for method chaining.
  BulkInsertBuilder table(String name) {
    _table = name;
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
    _ensureRowOrientedApis();
    _columns.add(
      BulkColumnSpec(
        name: name,
        colType: colType,
        nullable: nullable,
        maxLen: maxLen,
      ),
    );
    return this;
  }

  /// Adds a row of data to the bulk insert.
  ///
  /// The [values] list must contain values in the same order as columns
  /// were added, and must match the column count.
  ///
  /// The builder stores the row list reference directly for performance.
  /// Do not modify [values] after passing it to this method.
  ///
  /// Returns this builder for method chaining.
  /// Throws [StateError] if columns haven't been added yet.
  /// Throws [ArgumentError] if the row length doesn't match column count.
  BulkInsertBuilder addRow(List<dynamic> values) {
    _ensureRowOrientedApis();
    if (_columns.isEmpty) {
      throw StateError('Add columns before rows');
    }
    if (values.length != _columns.length) {
      throw ArgumentError(
        'Row length ${values.length} != column count ${_columns.length}',
      );
    }
    final rowNumber = _rows.length + 1;
    for (var c = 0; c < _columns.length; c++) {
      _validateValueForColumn(values[c], _columns[c], rowNumber);
    }
    _rows.add(values);
    return this;
  }

  /// Adds an i32 column from a typed [Int32List] (columnar mode).
  ///
  /// When [nullable] is true, pass [isNull] with one flag per row (`true` = SQL
  /// NULL). [values] at null rows are ignored on the wire (written as zero).
  ///
  /// Do not mutate [values] after calling this method.
  BulkInsertBuilder addColumnInt32(
    String name,
    Int32List values, {
    bool nullable = false,
    List<bool>? isNull,
  }) {
    _ensureColumnarApis();
    _registerColumnarColumn(
      BulkColumnSpec(
        name: name,
        colType: BulkColumnType.i32,
        nullable: nullable,
      ),
      _ColumnarInt32Data(values, isNull),
      isNull,
    );
    return this;
  }

  /// Adds an i64 column from a typed [Int64List] (columnar mode).
  BulkInsertBuilder addColumnInt64(
    String name,
    Int64List values, {
    bool nullable = false,
    List<bool>? isNull,
  }) {
    _ensureColumnarApis();
    _registerColumnarColumn(
      BulkColumnSpec(
        name: name,
        colType: BulkColumnType.i64,
        nullable: nullable,
      ),
      _ColumnarInt64Data(values, isNull),
      isNull,
    );
    return this;
  }

  /// Adds a text column from a [List] of UTF-8 strings (columnar mode).
  BulkInsertBuilder addColumnText(
    String name,
    List<String> values, {
    bool nullable = false,
    int maxLen = 0,
    List<bool>? isNull,
  }) {
    _ensureColumnarApis();
    final spec = BulkColumnSpec(
      name: name,
      colType: BulkColumnType.text,
      nullable: nullable,
      maxLen: maxLen,
    );
    for (var r = 0; r < values.length; r++) {
      if (!(isNull != null && isNull[r])) {
        _validateTextColumn(values[r], spec, r + 1);
      }
    }
    _registerColumnarColumn(
      spec,
      _ColumnarTextData(values, isNull),
      isNull,
    );
    return this;
  }

  /// Adds a decimal column from string literals (columnar mode).
  BulkInsertBuilder addColumnDecimal(
    String name,
    List<String> values, {
    bool nullable = false,
    int maxLen = 0,
    List<bool>? isNull,
  }) {
    _ensureColumnarApis();
    final spec = BulkColumnSpec(
      name: name,
      colType: BulkColumnType.decimal,
      nullable: nullable,
      maxLen: maxLen,
    );
    for (var r = 0; r < values.length; r++) {
      if (!(isNull != null && isNull[r])) {
        _validateTextColumn(values[r], spec, r + 1);
      }
    }
    _registerColumnarColumn(
      spec,
      _ColumnarDecimalData(values, isNull),
      isNull,
    );
    return this;
  }

  /// Adds a binary column from [Uint8List] cells (columnar mode).
  BulkInsertBuilder addColumnBinary(
    String name,
    List<Uint8List> values, {
    bool nullable = false,
    int maxLen = 0,
    List<bool>? isNull,
  }) {
    _ensureColumnarApis();
    final spec = BulkColumnSpec(
      name: name,
      colType: BulkColumnType.binary,
      nullable: nullable,
      maxLen: maxLen,
    );
    for (var r = 0; r < values.length; r++) {
      if (!(isNull != null && isNull[r])) {
        _validateBinaryColumn(values[r], spec, r + 1);
      }
    }
    _registerColumnarColumn(
      spec,
      _ColumnarBinaryData(values, isNull),
      isNull,
    );
    return this;
  }

  /// Adds a timestamp column from [DateTime] or [BulkTimestamp] values.
  BulkInsertBuilder addColumnTimestamp(
    String name,
    List<Object> values, {
    bool nullable = false,
    List<bool>? isNull,
  }) {
    _ensureColumnarApis();
    for (var r = 0; r < values.length; r++) {
      if (isNull != null && isNull[r]) {
        continue;
      }
      final v = values[r];
      if (v is! DateTime && v is! BulkTimestamp) {
        throw ArgumentError(
          'Column "$name" expects timestamp (DateTime/BulkTimestamp) but got '
          '$v (${v.runtimeType}) at row ${r + 1}.',
        );
      }
    }
    _registerColumnarColumn(
      BulkColumnSpec(
        name: name,
        colType: BulkColumnType.timestamp,
        nullable: nullable,
      ),
      _ColumnarTimestampData(values, isNull),
      isNull,
    );
    return this;
  }

  /// Gets the table name.
  String get tableName => _table;

  /// Gets the list of column names in the order they were added.
  List<String> get columnNames => _columns.map((c) => c.name).toList();

  /// Gets the number of rows in the builder (row- or column-oriented).
  int get rowCount => _effectiveRowCount;

  bool _isCellNull(int colIndex, int row) {
    if (_usesColumnar) {
      return _columnarData[colIndex].isNullAt(row);
    }
    return _rows[row][colIndex] == null;
  }

  dynamic _cellValue(int colIndex, int row) {
    if (_usesColumnar) {
      return _columnarData[colIndex].valueAt(row);
    }
    return _rows[row][colIndex];
  }

  /// Builds the binary data buffer for bulk insert.
  ///
  /// Version [BulkPayloadVersion.v2] is the default and preserves
  /// variable-width binary values, including embedded NUL bytes. Use
  /// [BulkPayloadVersion.legacy] only when talking to native engines that do
  /// not understand the versioned `BLK2` payload.
  ///
  /// Uses a two-pass strategy: phase 1 pre-encodes variable-width payloads and
  /// computes the exact total byte count; phase 2 writes directly into a
  /// single pre-sized [Uint8List].
  ///
  /// Validates that table name, columns, and at least one row are present.
  /// Returns a [Uint8List] containing the serialized bulk insert data.
  ///
  /// Throws [StateError] if table name is empty, no columns are defined,
  /// no rows have been added, or a non-nullable column contains null.
  Uint8List build({BulkPayloadVersion version = BulkPayloadVersion.v2}) {
    if (_table.isEmpty) {
      throw StateError('Table name required');
    }
    if (_columns.isEmpty) {
      throw StateError('At least one column required');
    }
    if (_effectiveRowCount == 0) {
      throw StateError('At least one row required');
    }

    // Keep a final nullability check because addRow stores row references.
    // Caller code can still mutate rows after insertion.
    if (!_usesColumnar) {
      for (var c = 0; c < _columns.length; c++) {
        final spec = _columns[c];
        if (!spec.nullable) {
          for (var r = 0; r < _rows.length; r++) {
            final value = _rows[r][c];
            if (value == null) {
              _throwNullabilityError(spec.name, r + 1);
            }
          }
        }
      }
    }

    final cache = _prepareEncodeCache(version);
    final out = Uint8List(cache.totalBytes);
    final w = _WriteCursor(out);

    if (version == BulkPayloadVersion.v2) {
      w.writeBytes(_bulkPayloadV2Magic);
      w.writeU16Le(_bulkPayloadV2Version);
      w.writeU16Le(_bulkPayloadV2Flags);
    }

    w
      ..writeU32Le(cache.tableBytes.length)
      ..writeBytes(cache.tableBytes)
      ..writeU32Le(_columns.length);

    for (var i = 0; i < _columns.length; i++) {
      final spec = _columns[i];
      final nameBytes = cache.columnNameBytes[i];
      w
        ..writeU32Le(nameBytes.length)
        ..writeBytes(nameBytes)
        ..writeByte(spec.tag)
        ..writeByte(spec.nullable ? 1 : 0)
        ..writeU32Le(spec.maxLen);
    }

    final rowCount = _effectiveRowCount;
    w.writeU32Le(rowCount);

    for (var c = 0; c < _columns.length; c++) {
      _writeColumn(
        w,
        version,
        _columns[c],
        c,
        rowCount,
        cache.v2VariableCells[c],
        _usesColumnar ? _columnarData[c] : null,
      );
    }

    assert(
      w.offset == cache.totalBytes,
      'bulk payload write cursor ${w.offset} != ${cache.totalBytes}',
    );
    return out;
  }

  _BulkEncodeCache _prepareEncodeCache(BulkPayloadVersion version) {
    final tableBytes = Uint8List.fromList(utf8.encode(_table));
    final columnNameBytes = _columns
        .map((spec) => Uint8List.fromList(utf8.encode(spec.name)))
        .toList(growable: false);

    var total = version == BulkPayloadVersion.v2 ? 8 : 0;
    total += 4 + tableBytes.length + 4;
    for (var i = 0; i < _columns.length; i++) {
      total += 4 + columnNameBytes[i].length + 1 + 1 + 4;
    }
    total += 4;

    final rowCount = _effectiveRowCount;
    final v2VariableCells = <List<Uint8List>?>[];
    for (var c = 0; c < _columns.length; c++) {
      total += _columnPayloadByteSize(
        version,
        _columns[c],
        c,
        rowCount,
        v2VariableCells,
      );
    }

    return _BulkEncodeCache(
      totalBytes: total,
      tableBytes: tableBytes,
      columnNameBytes: columnNameBytes,
      v2VariableCells: v2VariableCells,
    );
  }

  int _columnPayloadByteSize(
    BulkPayloadVersion version,
    BulkColumnSpec spec,
    int colIndex,
    int rowCount,
    List<List<Uint8List>?> cacheOut,
  ) {
    var size = 0;
    if (spec.nullable) {
      size += _nullBitmapSize(rowCount);
    }

    switch (spec.colType) {
      case BulkColumnType.i32:
        cacheOut.add(null);
        return size + 4 * rowCount;
      case BulkColumnType.i64:
        cacheOut.add(null);
        return size + 8 * rowCount;
      case BulkColumnType.timestamp:
        cacheOut.add(null);
        return size + 16 * rowCount;
      case BulkColumnType.text:
      case BulkColumnType.decimal:
        if (version == BulkPayloadVersion.v2) {
          final cells = <Uint8List>[];
          for (var r = 0; r < rowCount; r++) {
            final v = _cellValue(colIndex, r);
            final raw = _isCellNull(colIndex, r)
                ? Uint8List(0)
                : Uint8List.fromList(utf8.encode(v is String ? v : '$v'));
            cells.add(raw);
            size += 4 + raw.length;
          }
          cacheOut.add(cells);
          return size;
        }
        cacheOut.add(null);
        final maxLen = spec.maxLen > 0 ? spec.maxLen : 1;
        return size + maxLen * rowCount;
      case BulkColumnType.binary:
        if (version == BulkPayloadVersion.v2) {
          final cells = <Uint8List>[];
          for (var r = 0; r < rowCount; r++) {
            if (_isCellNull(colIndex, r)) {
              cells.add(Uint8List(0));
              size += 4;
              continue;
            }
            final v = _cellValue(colIndex, r);
            final raw = v is Uint8List ? v : Uint8List.fromList(v as List<int>);
            cells.add(raw);
            size += 4 + raw.length;
          }
          cacheOut.add(cells);
          return size;
        }
        cacheOut.add(null);
        final maxLen = spec.maxLen > 0 ? spec.maxLen : 1;
        return size + maxLen * rowCount;
    }
  }

  void _writeColumn(
    _WriteCursor w,
    BulkPayloadVersion version,
    BulkColumnSpec spec,
    int colIndex,
    int rowCount,
    List<Uint8List>? v2Cells,
    _ColumnarColumnData? columnar,
  ) {
    if (version == BulkPayloadVersion.v2 &&
        (spec.colType == BulkColumnType.text ||
            spec.colType == BulkColumnType.decimal ||
            spec.colType == BulkColumnType.binary)) {
      _writeColumnV2Variable(w, spec, colIndex, rowCount, v2Cells!);
      return;
    }
    _writeColumnLegacy(w, spec, colIndex, rowCount, columnar);
  }

  void _writeColumnLegacy(
    _WriteCursor w,
    BulkColumnSpec spec,
    int colIndex,
    int rowCount,
    _ColumnarColumnData? columnar,
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
            if (_isCellNull(colIndex, r)) _setNullAt(nullBitmap, r);
          }
          w.writeBytes(nullBitmap);
        }
        if (columnar is _ColumnarInt32Data && nullBitmap == null) {
          w.writeInt32List(columnar.values);
          return;
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _cellValue(colIndex, r);
          final i = _isCellNull(colIndex, r)
              ? 0
              : (v is int ? v : int.tryParse('$v') ?? 0);
          w.writeI32Le(i);
        }
      case BulkColumnType.i64:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            if (_isCellNull(colIndex, r)) _setNullAt(nullBitmap, r);
          }
          w.writeBytes(nullBitmap);
        }
        if (columnar is _ColumnarInt64Data && nullBitmap == null) {
          w.writeInt64List(columnar.values);
          return;
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _cellValue(colIndex, r);
          final i = _isCellNull(colIndex, r)
              ? 0
              : (v is int ? v : int.tryParse('$v') ?? 0);
          w.writeI64Le(i);
        }
      case BulkColumnType.text:
      case BulkColumnType.decimal:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            if (_isCellNull(colIndex, r)) _setNullAt(nullBitmap, r);
          }
          w.writeBytes(nullBitmap);
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _cellValue(colIndex, r);
          final List<int> raw;
          if (_isCellNull(colIndex, r)) {
            raw = const <int>[];
          } else if (v is String) {
            raw = utf8.encode(v);
          } else {
            raw = utf8.encode('$v');
          }
          final len = raw.length.clamp(0, maxLen);
          w.writeBytesRange(raw, 0, len);
          for (var i = len; i < maxLen; i++) {
            w.writeByte(0);
          }
        }
      case BulkColumnType.binary:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            if (_isCellNull(colIndex, r)) _setNullAt(nullBitmap, r);
          }
          w.writeBytes(nullBitmap);
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _cellValue(colIndex, r);
          final List<int> raw;
          if (_isCellNull(colIndex, r)) {
            raw = const <int>[];
          } else if (v is Uint8List) {
            raw = v;
          } else if (v is List<int>) {
            raw = v;
          } else {
            raw = const <int>[];
          }
          final len = raw.length.clamp(0, maxLen);
          w.writeBytesRange(raw, 0, len);
          for (var i = len; i < maxLen; i++) {
            w.writeByte(0);
          }
        }
      case BulkColumnType.timestamp:
        if (nullBitmap != null) {
          for (var r = 0; r < rowCount; r++) {
            if (_isCellNull(colIndex, r)) _setNullAt(nullBitmap, r);
          }
          w.writeBytes(nullBitmap);
        }
        for (var r = 0; r < rowCount; r++) {
          final v = _cellValue(colIndex, r);
          BulkTimestamp t;
          if (_isCellNull(colIndex, r)) {
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
          w
            ..writeI16Le(t.year)
            ..writeU16Le(t.month)
            ..writeU16Le(t.day)
            ..writeU16Le(t.hour)
            ..writeU16Le(t.minute)
            ..writeU16Le(t.second)
            ..writeU32Le(t.fraction);
        }
    }
  }

  void _writeColumnV2Variable(
    _WriteCursor w,
    BulkColumnSpec spec,
    int colIndex,
    int rowCount,
    List<Uint8List> cells,
  ) {
    List<int>? nullBitmap;
    if (spec.nullable) {
      nullBitmap = List.filled(_nullBitmapSize(rowCount), 0);
      for (var r = 0; r < rowCount; r++) {
        if (_isCellNull(colIndex, r)) _setNullAt(nullBitmap, r);
      }
      w.writeBytes(nullBitmap);
    }

    for (var r = 0; r < rowCount; r++) {
      final raw = cells[r];
      w
        ..writeU32Le(raw.length)
        ..writeBytes(raw);
    }
  }
}

extension on BulkColumnSpec {
  int get tag => colType.tag;
}

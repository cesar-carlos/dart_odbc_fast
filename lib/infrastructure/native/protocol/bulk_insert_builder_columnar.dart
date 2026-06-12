part of 'bulk_insert_builder.dart';

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

mixin _BulkInsertColumnarApi on _BulkInsertBuilderState {
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
    return _self;
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
    return _self;
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
    return _self;
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
    return _self;
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
    return _self;
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
    return _self;
  }
}

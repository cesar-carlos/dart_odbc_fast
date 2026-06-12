part of 'bulk_insert_builder.dart';

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

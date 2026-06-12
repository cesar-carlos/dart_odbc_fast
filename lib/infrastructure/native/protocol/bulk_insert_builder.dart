library;

import 'dart:convert';
import 'dart:typed_data';

part 'bulk_insert_builder_validation.dart';
part 'bulk_insert_builder_types.dart';
part 'bulk_insert_builder_wire_helpers.dart';
part 'bulk_insert_builder_columnar.dart';
part 'bulk_insert_builder_row.dart';
part 'bulk_insert_builder_wire_encode.dart';

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

abstract class _BulkInsertBuilderState {
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

  BulkInsertBuilder get _self => this as BulkInsertBuilder;
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
class BulkInsertBuilder extends _BulkInsertBuilderState
    with _BulkInsertRowApi, _BulkInsertColumnarApi, _BulkInsertWireEncode {
  /// Creates a new [BulkInsertBuilder] instance.
  BulkInsertBuilder();
}

extension on BulkColumnSpec {
  int get tag => colType.tag;
}

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
  final b = ByteData(4);
  b.setUint32(0, v, Endian.little);
  return b.buffer.asUint8List(0, 4).toList();
}

List<int> _i32Le(int v) {
  final b = ByteData(4);
  b.setInt32(0, v, Endian.little);
  return b.buffer.asUint8List(0, 4).toList();
}

List<int> _i64Le(int v) {
  final b = ByteData(8);
  b.setInt64(0, v, Endian.little);
  return b.buffer.asUint8List(0, 8).toList();
}

List<int> _u16Le(int v) {
  final b = ByteData(2);
  b.setUint16(0, v, Endian.little);
  return b.buffer.asUint8List(0, 2).toList();
}

List<int> _i16Le(int v) {
  final b = ByteData(2);
  b.setInt16(0, v, Endian.little);
  return b.buffer.asUint8List(0, 2).toList();
}

enum BulkColumnType {
  i32(_tagI32),
  i64(_tagI64),
  text(_tagText),
  decimal(_tagDecimal),
  binary(_tagBinary),
  timestamp(_tagTimestamp);

  const BulkColumnType(this.tag);
  final int tag;
}

class BulkColumnSpec {
  BulkColumnSpec({
    required this.name,
    required this.colType,
    this.nullable = false,
    this.maxLen = 0,
  });

  final String name;
  final BulkColumnType colType;
  final bool nullable;
  final int maxLen;
}

class BulkTimestamp {
  const BulkTimestamp({
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
    this.fraction = 0,
  });

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;
  final int fraction;

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

class BulkInsertBuilder {
  BulkInsertBuilder();

  String _table = '';
  final List<BulkColumnSpec> _columns = [];
  final List<List<dynamic>> _rows = [];

  BulkInsertBuilder table(String name) {
    _table = name;
    return this;
  }

  BulkInsertBuilder addColumn(
    String name,
    BulkColumnType colType, {
    bool nullable = false,
    int maxLen = 0,
  }) {
    _columns.add(BulkColumnSpec(
      name: name,
      colType: colType,
      nullable: nullable,
      maxLen: maxLen,
    ));
    return this;
  }

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
    return this;
  }

  String get tableName => _table;

  List<String> get columnNames => _columns.map((c) => c.name).toList();

  int get rowCount => _rows.length;

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
    out.addAll(_u32Le(tableBytes.length));
    out.addAll(tableBytes);
    out.addAll(_u32Le(_columns.length));

    for (final spec in _columns) {
      final nameBytes = utf8.encode(spec.name);
      out.addAll(_u32Le(nameBytes.length));
      out.addAll(nameBytes);
      out.add(spec.tag);
      out.add(spec.nullable ? 1 : 0);
      out.addAll(_u32Le(spec.maxLen));
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
        break;
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
        break;
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
        break;
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
        break;
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
          out.addAll(_i16Le(t.year));
          out.addAll(_u16Le(t.month));
          out.addAll(_u16Le(t.day));
          out.addAll(_u16Le(t.hour));
          out.addAll(_u16Le(t.minute));
          out.addAll(_u16Le(t.second));
          out.addAll(_u32Le(t.fraction));
        }
        break;
    }
  }
}

extension on BulkColumnSpec {
  int get tag => colType.tag;
}

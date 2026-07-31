import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/infrastructure/native/columnar_decompress_ffi.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_cell_decode.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_constants.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_types.dart';
import 'package:odbc_fast/infrastructure/native/protocol/lazy_string.dart';
import 'package:odbc_fast/infrastructure/native/protocol/odbc_type.dart';
import 'package:odbc_fast/infrastructure/native/protocol/protocol_ascii_parse.dart';

const Endian _littleEndian = Endian.little;

ParsedRowBuffer parseColumnarV2ToRowBuffer(Uint8List data) {
  if (data.length < BinaryProtocolConstants.headerSizeColumnarV2) {
    throw const FormatException('Columnar v2: buffer too small');
  }
  final colCount = ByteData.sublistView(
    data,
    8,
    10,
  ).getUint16(0, _littleEndian);
  final rowCount = ByteData.sublistView(
    data,
    10,
    14,
  ).getUint32(0, _littleEndian);
  final paySize = ByteData.sublistView(
    data,
    15,
    19,
  ).getUint32(0, _littleEndian);
  if (data.length < BinaryProtocolConstants.headerSizeColumnarV2 + paySize) {
    throw const FormatException('Columnar v2: truncated payload');
  }
  if (colCount > data.length || rowCount > data.length) {
    throw FormatException(
      'Columnar v2 header oversized: rows=$rowCount, cols=$colCount, '
      'buffer=${data.length}',
    );
  }
  if (colCount > 0 && rowCount > paySize) {
    throw FormatException(
      'Columnar v2 header inconsistent: rows=$rowCount cannot fit in '
      'payload=$paySize',
    );
  }
  if (colCount == 0) {
    return ParsedRowBuffer(
      columns: [],
      rows: [],
      rowCount: 0,
      columnCount: 0,
    );
  }
  var off = BinaryProtocolConstants.headerSizeColumnarV2;
  final end = BinaryProtocolConstants.headerSizeColumnarV2 + paySize;
  final columnMetas = <ColumnMetadata>[];
  final rows = List<List<dynamic>>.generate(
    rowCount,
    (_) => List<dynamic>.filled(colCount, null),
  );

  for (var c = 0; c < colCount; c++) {
    if (off + 4 > end) {
      throw const FormatException('Columnar v2: metadata truncated');
    }
    final odbcType = ByteData.sublistView(
      data,
      off,
      off + 2,
    ).getUint16(0, _littleEndian);
    off += 2;
    final nameLen = ByteData.sublistView(
      data,
      off,
      off + 2,
    ).getUint16(0, _littleEndian);
    off += 2;
    if (off + nameLen > end) {
      throw const FormatException('Columnar v2: name truncated');
    }
    final name = utf8.decode(
      Uint8List.sublistView(data, off, off + nameLen),
      allowMalformed: true,
    );
    off += nameLen;
    columnMetas.add(ColumnMetadata(name: name, odbcType: odbcType));

    if (off >= end) {
      throw const FormatException('Columnar v2: missing column payload');
    }
    final isCompressed = data[off++];
    final raw = _readColumnarColumnPayload(
      data: data,
      off: off,
      end: end,
      isCompressed: isCompressed,
    );
    off = raw.nextOffset;
    fillColumnarRowsIntoRowBuffer(
      odbcType: odbcType,
      raw: raw.bytes,
      columnIndex: c,
      rows: rows,
    );
  }
  if (off != end) {
    throw const FormatException('Columnar v2: extra bytes in column payload');
  }
  return ParsedRowBuffer(
    columns: columnMetas,
    rows: rows,
    rowCount: rowCount,
    columnCount: colCount,
  );
}

/// Decodes a columnar v2 wire message directly into [TypedColumnarResult]
/// without materializing row-major `List<List<dynamic>>`.
TypedColumnarResult parseColumnarV2ToTyped(Uint8List data) {
  if (data.length < BinaryProtocolConstants.headerSizeColumnarV2) {
    throw const FormatException('Columnar v2: buffer too small');
  }
  final readMagic =
      ByteData.sublistView(data, 0, 4).getUint32(0, _littleEndian);
  if (readMagic != BinaryProtocolConstants.magic) {
    throw FormatException(
      'Invalid magic number: 0x${readMagic.toRadixString(16)}',
    );
  }
  final version = ByteData.sublistView(data, 4, 6).getUint16(0, _littleEndian);
  if (version != BinaryProtocolConstants.protocolVersionColumnarV2) {
    throw FormatException('Not a columnar v2 buffer: version=$version');
  }

  final colCount =
      ByteData.sublistView(data, 8, 10).getUint16(0, _littleEndian);
  final rowCount =
      ByteData.sublistView(data, 10, 14).getUint32(0, _littleEndian);
  final paySize =
      ByteData.sublistView(data, 15, 19).getUint32(0, _littleEndian);
  final end = BinaryProtocolConstants.headerSizeColumnarV2 + paySize;
  if (data.length < end) {
    throw const FormatException('Columnar v2: truncated payload');
  }
  if (colCount > data.length || rowCount > data.length) {
    throw FormatException(
      'Columnar v2 header oversized: rows=$rowCount, cols=$colCount, '
      'buffer=${data.length}',
    );
  }
  if (colCount > 0 && rowCount > paySize) {
    throw FormatException(
      'Columnar v2 header inconsistent: rows=$rowCount cannot fit in '
      'payload=$paySize',
    );
  }
  if (colCount == 0) {
    return TypedColumnarResult(columns: const [], rowCount: 0);
  }

  var off = BinaryProtocolConstants.headerSizeColumnarV2;
  final typedColumns = <TypedColumn>[];

  for (var c = 0; c < colCount; c++) {
    if (off + 4 > end) {
      throw const FormatException('Columnar v2: metadata truncated');
    }
    final odbcType = ByteData.sublistView(
      data,
      off,
      off + 2,
    ).getUint16(0, _littleEndian);
    off += 2;
    final nameLen = ByteData.sublistView(
      data,
      off,
      off + 2,
    ).getUint16(0, _littleEndian);
    off += 2;
    if (off + nameLen > end) {
      throw const FormatException('Columnar v2: name truncated');
    }
    final name = utf8.decode(
      Uint8List.sublistView(data, off, off + nameLen),
      allowMalformed: true,
    );
    off += nameLen;

    if (off >= end) {
      throw const FormatException('Columnar v2: missing column payload');
    }
    final isCompressed = data[off++];
    final raw = _readColumnarColumnPayload(
      data: data,
      off: off,
      end: end,
      isCompressed: isCompressed,
    );
    off = raw.nextOffset;
    typedColumns.add(
      _buildTypedColumn(
        name: name,
        odbcType: odbcType,
        raw: raw.bytes,
        rowCount: rowCount,
      ),
    );
  }
  if (off != end) {
    throw const FormatException('Columnar v2: extra bytes in column payload');
  }

  return TypedColumnarResult(columns: typedColumns, rowCount: rowCount);
}

class _ColumnarRawColumn {
  const _ColumnarRawColumn({required this.bytes, required this.nextOffset});

  final Uint8List bytes;
  final int nextOffset;
}

_ColumnarRawColumn _readColumnarColumnPayload({
  required Uint8List data,
  required int off,
  required int end,
  required int isCompressed,
}) {
  var offset = off;
  if (isCompressed != 0) {
    if (offset + 1 + 4 > end) {
      throw const FormatException('Columnar v2: compressed header truncated');
    }
    final algorithm = data[offset++];
    if (offset + 4 > end) {
      throw const FormatException('Columnar v2: compressed size truncated');
    }
    final compLen = ByteData.sublistView(
      data,
      offset,
      offset + 4,
    ).getUint32(0, _littleEndian);
    offset += 4;
    if (offset + compLen > end) {
      throw const FormatException('Columnar v2: compressed data truncated');
    }
    final comp = Uint8List.sublistView(data, offset, offset + compLen);
    offset += compLen;
    final decomp = columnarDecompressWithNative(comp, algorithm);
    if (decomp == null) {
      final haveApi = isColumnarNativeDecompressAvailable;
      final hint = haveApi
          ? 'odbc_columnar_decompress rejected the payload (wrong '
              'algorithm id, corrupt data, or size mismatch).'
          : 'Native decompress symbols were not loaded.';
      throw FormatException(
        'Columnar v2: native decompress failed '
        '(algorithm=$algorithm, compBytes=$compLen, '
        'odbcDecompressFfi=$haveApi). $hint',
      );
    }
    return _ColumnarRawColumn(bytes: decomp, nextOffset: offset);
  }

  if (offset + 4 > end) {
    throw const FormatException('Columnar v2: raw size truncated');
  }
  final rawLen = ByteData.sublistView(
    data,
    offset,
    offset + 4,
  ).getUint32(0, _littleEndian);
  offset += 4;
  if (offset + rawLen > end) {
    throw const FormatException('Columnar v2: raw data truncated');
  }
  final raw = Uint8List.sublistView(data, offset, offset + rawLen);
  return _ColumnarRawColumn(bytes: raw, nextOffset: offset + rawLen);
}

TypedColumn _buildTypedColumn({
  required String name,
  required int odbcType,
  required Uint8List raw,
  required int rowCount,
}) {
  final odbc = OdbcType.fromDiscriminant(odbcType);
  if (odbc == OdbcType.integer) {
    return _decodeInt32Column(name: name, raw: raw, rowCount: rowCount);
  }
  if (odbc == OdbcType.bigInt) {
    return _decodeInt64Column(name: name, raw: raw, rowCount: rowCount);
  }
  if (odbc == OdbcType.float || odbc == OdbcType.doublePrecision) {
    return _decodeFloat64Column(name: name, raw: raw, rowCount: rowCount);
  }
  return _decodeObjectColumn(
    name: name,
    odbcType: odbc,
    raw: raw,
    rowCount: rowCount,
  );
}

TypedColumnInt32 _decodeInt32Column({
  required String name,
  required Uint8List raw,
  required int rowCount,
}) {
  final values = Int32List(rowCount);
  final bitmap = Uint8List((rowCount + 7) >> 3);
  final bd = ByteData.sublistView(raw);
  var p = 0;
  for (var i = 0; i < rowCount; i++) {
    if (p >= raw.length) {
      throw const FormatException('Columnar v2: int column truncated');
    }
    final n = raw[p++];
    if (n == 1) {
      setNullBitmapBit(bitmap, i);
      continue;
    }
    if (p + 4 > raw.length) {
      throw const FormatException('Columnar v2: int cell truncated');
    }
    values[i] = bd.getInt32(p, _littleEndian);
    p += 4;
  }
  if (p != raw.length) {
    throw const FormatException('Columnar v2: int column not fully consumed');
  }
  return TypedColumnInt32(name: name, values: values, nullBitmap: bitmap);
}

TypedColumnInt64 _decodeInt64Column({
  required String name,
  required Uint8List raw,
  required int rowCount,
}) {
  final values = Int64List(rowCount);
  final bitmap = Uint8List((rowCount + 7) >> 3);
  final bd = ByteData.sublistView(raw);
  var p = 0;
  for (var i = 0; i < rowCount; i++) {
    if (p >= raw.length) {
      throw const FormatException('Columnar v2: bigint column truncated');
    }
    final n = raw[p++];
    if (n == 1) {
      setNullBitmapBit(bitmap, i);
      continue;
    }
    if (p + 8 > raw.length) {
      throw const FormatException('Columnar v2: bigint cell truncated');
    }
    values[i] = bd.getInt64(p, _littleEndian);
    p += 8;
  }
  if (p != raw.length) {
    throw const FormatException(
      'Columnar v2: bigint column not fully consumed',
    );
  }
  return TypedColumnInt64(name: name, values: values, nullBitmap: bitmap);
}

/// Float/double wire cells are UTF-8 text; parse once into [Float64List].
TypedColumnFloat64 _decodeFloat64Column({
  required String name,
  required Uint8List raw,
  required int rowCount,
}) {
  final values = Float64List(rowCount);
  final bitmap = Uint8List((rowCount + 7) >> 3);
  final bd = ByteData.sublistView(raw);
  var p = 0;
  for (var i = 0; i < rowCount; i++) {
    if (p >= raw.length) {
      throw const FormatException('Columnar v2: float column truncated');
    }
    final n = raw[p++];
    if (n == 1) {
      setNullBitmapBit(bitmap, i);
      continue;
    }
    if (p + 4 > raw.length) {
      throw const FormatException('Columnar v2: float len truncated');
    }
    final bl = bd.getUint32(p, _littleEndian);
    p += 4;
    if (p + bl > raw.length) {
      throw const FormatException('Columnar v2: float data truncated');
    }
    final bytes = Uint8List.sublistView(raw, p, p + bl);
    p += bl;
    values[i] = _parseFloat64CellBytes(bytes);
  }
  if (p != raw.length) {
    throw const FormatException(
      'Columnar v2: float column not fully consumed',
    );
  }
  return TypedColumnFloat64(name: name, values: values, nullBitmap: bitmap);
}

double _parseFloat64CellBytes(Uint8List bytes) {
  // Prefer legacy UTF-8 float text first so ASCII specials like "Infinity"
  // (exactly 8 bytes) are not misread as IEEE-754 payloads.
  final parsed = tryParseAsciiFloat64(bytes);
  if (parsed != null) {
    return parsed;
  }
  if (bytes.length == 8) {
    return ByteData.sublistView(bytes).getFloat64(0, Endian.little);
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  throw FormatException('Columnar v2: cannot parse float cell "$text"');
}

TypedColumn _decodeObjectColumn({
  required String name,
  required OdbcType odbcType,
  required Uint8List raw,
  required int rowCount,
}) {
  final kind = _typedKindForOdbcType(odbcType);
  final bd = ByteData.sublistView(raw);
  var p = 0;

  Object? readCell() {
    if (p >= raw.length) {
      throw const FormatException('Columnar v2: object column truncated');
    }
    final n = raw[p++];
    if (n == 1) {
      return null;
    }
    if (odbcType == OdbcType.binary) {
      if (p + 4 > raw.length) {
        throw const FormatException('Columnar v2: binary len truncated');
      }
      final bl = bd.getUint32(p, _littleEndian);
      p += 4;
      if (p + bl > raw.length) {
        throw const FormatException('Columnar v2: binary data truncated');
      }
      final bytes = Uint8List.sublistView(raw, p, p + bl);
      p += bl;
      return bytes;
    }
    if (p + 4 > raw.length) {
      throw const FormatException('Columnar v2: varchar len truncated');
    }
    final bl = bd.getUint32(p, _littleEndian);
    p += 4;
    if (p + bl > raw.length) {
      throw const FormatException('Columnar v2: varchar data truncated');
    }
    final bytes = Uint8List.sublistView(raw, p, p + bl);
    p += bl;
    return decodeProtocolCell(bytes, odbcType.discriminant);
  }

  TypedColumn build(List<Object?> Function() fill) {
    final values = fill();
    if (p != raw.length) {
      throw const FormatException(
        'Columnar v2: object column not fully consumed',
      );
    }
    return _typedObjectColumnForKind(name, kind, values);
  }

  switch (kind) {
    case TypedColumnKind.bytes:
      final values = List<Uint8List?>.filled(rowCount, null);
      for (var i = 0; i < rowCount; i++) {
        values[i] = readCell() as Uint8List?;
      }
      if (p != raw.length) {
        throw const FormatException(
          'Columnar v2: object column not fully consumed',
        );
      }
      return TypedColumnObject<Uint8List>(
        name: name,
        kind: kind,
        values: values,
      );
    case TypedColumnKind.bool_:
      final values = List<bool?>.filled(rowCount, null);
      for (var i = 0; i < rowCount; i++) {
        values[i] = _coerceBoolCell(readCell());
      }
      if (p != raw.length) {
        throw const FormatException(
          'Columnar v2: object column not fully consumed',
        );
      }
      return TypedColumnObject<bool>(
        name: name,
        kind: kind,
        values: values,
      );
    case TypedColumnKind.string:
      if (binaryProtocolLazyStringsActive) {
        final values = List<Object?>.filled(rowCount, null);
        for (var i = 0; i < rowCount; i++) {
          values[i] = readCell();
        }
        if (p != raw.length) {
          throw const FormatException(
            'Columnar v2: object column not fully consumed',
          );
        }
        return TypedColumnObject<Object>(
          name: name,
          kind: kind,
          values: values,
        );
      }
      final values = List<String?>.filled(rowCount, null);
      for (var i = 0; i < rowCount; i++) {
        final v = readCell();
        if (v == null) {
          values[i] = null;
        } else if (v is String) {
          values[i] = v;
        } else {
          values[i] = v.toString();
        }
      }
      if (p != raw.length) {
        throw const FormatException(
          'Columnar v2: object column not fully consumed',
        );
      }
      return TypedColumnObject<String>(
        name: name,
        kind: kind,
        values: values,
      );
    case TypedColumnKind.dateTime:
      final values = List<DateTime?>.filled(rowCount, null);
      for (var i = 0; i < rowCount; i++) {
        values[i] = _coerceDateTimeCell(readCell());
      }
      if (p != raw.length) {
        throw const FormatException(
          'Columnar v2: object column not fully consumed',
        );
      }
      return TypedColumnObject<DateTime>(
        name: name,
        kind: kind,
        values: values,
      );
    case TypedColumnKind.decimal:
    case TypedColumnKind.unknown:
    case TypedColumnKind.int32:
    case TypedColumnKind.int64:
    case TypedColumnKind.float64:
      // Handled in [_buildTypedColumn] via [_decodeFloat64Column].
      return build(() {
        final values = List<Object?>.filled(rowCount, null);
        for (var i = 0; i < rowCount; i++) {
          values[i] = readCell();
        }
        return values;
      });
  }
}

TypedColumn _typedObjectColumnForKind(
  String name,
  TypedColumnKind kind,
  List<Object?> values,
) {
  return TypedColumnObject<Object>(
    name: name,
    kind: kind,
    values: values,
  );
}

TypedColumnKind _typedKindForOdbcType(OdbcType odbcType) {
  return switch (odbcType) {
    OdbcType.integer => TypedColumnKind.int32,
    OdbcType.bigInt => TypedColumnKind.int64,
    OdbcType.binary => TypedColumnKind.bytes,
    OdbcType.boolean => TypedColumnKind.bool_,
    OdbcType.float || OdbcType.doublePrecision => TypedColumnKind.float64,
    OdbcType.decimal || OdbcType.money => TypedColumnKind.decimal,
    OdbcType.date ||
    OdbcType.timestamp ||
    OdbcType.timestampWithTz ||
    OdbcType.datetimeOffset ||
    OdbcType.time =>
      TypedColumnKind.dateTime,
    _ => TypedColumnKind.string,
  };
}

/// Wire boolean cells are UTF-8 text (`0`/`1`/`true`/`false`); coerce to [bool].
bool? _coerceBoolCell(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is bool) {
    return value;
  }
  if (value is num) {
    if (value == 0) {
      return false;
    }
    if (value == 1) {
      return true;
    }
  }
  if (value is Uint8List) {
    final parsed = tryParseAsciiBool(value);
    if (parsed != null) {
      return parsed;
    }
  }
  if (value is LazyString) {
    final parsed = tryParseAsciiBool(value.bytes);
    if (parsed != null) {
      return parsed;
    }
  }
  final text =
      (value is String ? value : value.toString()).trim().toLowerCase();
  if (text == '0' || text == 'false') {
    return false;
  }
  if (text == '1' || text == 'true') {
    return true;
  }
  throw FormatException('Columnar v2: cannot parse bool cell "$value"');
}

/// Wire datetime cells are UTF-8 text (see [OdbcType] table); coerce to
/// [DateTime] for [TypedColumnObject].
DateTime? _coerceDateTimeCell(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is DateTime) {
    return value;
  }
  if (value is Uint8List) {
    final fast = tryParseAsciiDateTime(value);
    if (fast != null) {
      return fast;
    }
  }
  if (value is LazyString) {
    final fast = tryParseAsciiDateTime(value.bytes);
    if (fast != null) {
      return fast;
    }
  }
  final text = value is String ? value : value.toString();
  final parsed = DateTime.tryParse(text);
  if (parsed != null) {
    return parsed;
  }
  // SQL Server often emits `YYYY-MM-DD HH:MM:SS` (space); ISO prefers `T`.
  final space = text.indexOf(' ');
  if (space > 0) {
    final withT = '${text.substring(0, space)}T${text.substring(space + 1)}';
    final normalized = DateTime.tryParse(withT);
    if (normalized != null) {
      return normalized;
    }
  }
  throw FormatException(
    'Columnar v2: cannot parse datetime cell "$text"',
  );
}

void fillColumnarRowsIntoRowBuffer({
  required int odbcType,
  required Uint8List raw,
  required int columnIndex,
  required List<List<dynamic>> rows,
}) {
  final odbc = OdbcType.fromDiscriminant(odbcType);
  final bd = ByteData.sublistView(raw);
  var p = 0;
  final rowCount = rows.length;
  for (var i = 0; i < rowCount; i++) {
    if (p >= raw.length) {
      throw const FormatException('Columnar v2: row cells truncated');
    }
    if (odbc == OdbcType.integer) {
      final n = raw[p++];
      if (n == 1) {
        rows[i][columnIndex] = null;
      } else {
        if (p + 4 > raw.length) {
          throw const FormatException('Columnar v2: int cell truncated');
        }
        rows[i][columnIndex] = bd.getInt32(p, _littleEndian);
        p += 4;
      }
    } else if (odbc == OdbcType.bigInt) {
      final n = raw[p++];
      if (n == 1) {
        rows[i][columnIndex] = null;
      } else {
        if (p + 8 > raw.length) {
          throw const FormatException('Columnar v2: bigint cell truncated');
        }
        rows[i][columnIndex] = bd.getInt64(p, _littleEndian);
        p += 8;
      }
    } else {
      final n = raw[p++];
      if (n == 1) {
        rows[i][columnIndex] = null;
      } else {
        if (p + 4 > raw.length) {
          throw const FormatException('Columnar v2: varchar len truncated');
        }
        final bl = bd.getUint32(p, _littleEndian);
        p += 4;
        if (p + bl > raw.length) {
          throw const FormatException('Columnar v2: varchar data truncated');
        }
        final bytes = Uint8List.sublistView(raw, p, p + bl);
        p += bl;
        rows[i][columnIndex] = decodeProtocolCell(bytes, odbcType);
      }
    }
  }
  if (p != raw.length) {
    throw const FormatException('Columnar v2: raw not fully consumed');
  }
}

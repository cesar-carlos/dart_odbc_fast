import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/infrastructure/native/columnar_decompress_ffi.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_cell_decode.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_constants.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_types.dart';
import 'package:odbc_fast/infrastructure/native/protocol/odbc_type.dart';

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
    growable: false,
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

TypedColumn _decodeObjectColumn({
  required String name,
  required OdbcType odbcType,
  required Uint8List raw,
  required int rowCount,
}) {
  final kind = _typedKindForOdbcType(odbcType);
  final values = List<Object?>.filled(rowCount, null);
  final bd = ByteData.sublistView(raw);
  var p = 0;
  for (var i = 0; i < rowCount; i++) {
    if (p >= raw.length) {
      throw const FormatException('Columnar v2: object column truncated');
    }
    final n = raw[p++];
    if (n == 1) {
      continue;
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
      values[i] = Uint8List.sublistView(raw, p, p + bl);
      p += bl;
      continue;
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
    values[i] = decodeProtocolCell(bytes, odbcType.discriminant);
  }
  if (p != raw.length) {
    throw const FormatException(
      'Columnar v2: object column not fully consumed',
    );
  }
  return _typedObjectColumnForKind(name, kind, values);
}

TypedColumn _typedObjectColumnForKind(
  String name,
  TypedColumnKind kind,
  List<Object?> values,
) {
  return switch (kind) {
    TypedColumnKind.bytes => TypedColumnObject<Uint8List>(
        name: name,
        kind: kind,
        values: List<Uint8List?>.generate(
          values.length,
          (i) => values[i] as Uint8List?,
          growable: false,
        ),
      ),
    TypedColumnKind.bool_ => TypedColumnObject<bool>(
        name: name,
        kind: kind,
        values: List<bool?>.generate(
          values.length,
          (i) => values[i] as bool?,
          growable: false,
        ),
      ),
    TypedColumnKind.string => binaryProtocolLazyStringsActive
        ? TypedColumnObject<Object>(
            name: name,
            kind: kind,
            values: List<Object?>.generate(
              values.length,
              (i) => values[i],
              growable: false,
            ),
          )
        : TypedColumnObject<String>(
            name: name,
            kind: kind,
            values: List<String?>.generate(
              values.length,
              (i) {
                final v = values[i];
                if (v == null) return null;
                if (v is String) return v;
                return v.toString();
              },
              growable: false,
            ),
          ),
    TypedColumnKind.dateTime => TypedColumnObject<DateTime>(
        name: name,
        kind: kind,
        values: List<DateTime?>.generate(
          values.length,
          (i) => values[i] as DateTime?,
          growable: false,
        ),
      ),
    TypedColumnKind.decimal ||
    TypedColumnKind.unknown ||
    TypedColumnKind.int32 ||
    TypedColumnKind.int64 ||
    TypedColumnKind.float64 =>
      TypedColumnObject<Object>(
        name: name,
        kind: kind,
        values: values,
      ),
  };
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

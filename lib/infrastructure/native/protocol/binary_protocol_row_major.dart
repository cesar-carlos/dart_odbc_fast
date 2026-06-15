import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_cell_decode.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_constants.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_reader.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_types.dart';

ParsedRowBuffer parseRowMajorV1(Uint8List data) {
  final reader = BinaryProtocolBufferReader(data);

  final readMagic = reader.readUint32();
  if (readMagic != BinaryProtocolConstants.magic) {
    throw FormatException(
      'Invalid magic number: 0x${readMagic.toRadixString(16)}',
    );
  }

  final version = reader.readUint16();
  if (version != BinaryProtocolConstants.protocolVersionRowMajor) {
    throw FormatException('Not a v1 buffer in parseRowMajorV1: $version');
  }

  final columnCount = reader.readUint16();
  final rowCount = reader.readUint32();
  reader.readUint32();

  if (columnCount > data.length || rowCount > data.length) {
    throw FormatException(
      'v1 buffer header oversized: rows=$rowCount, cols=$columnCount, '
      'buffer=${data.length}',
    );
  }
  if (columnCount > 0 && rowCount > data.length ~/ columnCount) {
    throw FormatException(
      'v1 buffer header inconsistent: rows=$rowCount, cols=$columnCount '
      'cannot fit in buffer=${data.length}',
    );
  }

  final columns = <ColumnMetadata>[];
  for (var i = 0; i < columnCount; i++) {
    final odbcType = reader.readUint16();
    final nameLen = reader.readUint16();
    final name = reader.readString(nameLen);
    columns.add(ColumnMetadata(name: name, odbcType: odbcType));
  }

  final rows = List<List<dynamic>>.generate(
    rowCount,
    (_) => List<dynamic>.filled(columnCount, null),
    growable: false,
  );
  for (var r = 0; r < rowCount; r++) {
    for (var c = 0; c < columnCount; c++) {
      final isNull = reader.readUint8();
      if (isNull != 1) {
        final cellLen = reader.readUint32();
        final cellBytes = reader.readBytes(cellLen);
        rows[r][c] = decodeProtocolCell(cellBytes, columns[c].odbcType);
      }
    }
  }

  return ParsedRowBuffer(
    columns: columns,
    rows: rows,
    rowCount: rowCount,
    columnCount: columnCount,
  );
}

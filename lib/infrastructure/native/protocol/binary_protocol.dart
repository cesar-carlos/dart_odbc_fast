import 'dart:typed_data';

class ColumnMetadata {
  final String name;
  final int odbcType;

  const ColumnMetadata({
    required this.name,
    required this.odbcType,
  });
}

class ParsedRowBuffer {
  final List<ColumnMetadata> columns;
  final List<List<dynamic>> rows;
  final int rowCount;
  final int columnCount;

  const ParsedRowBuffer({
    required this.columns,
    required this.rows,
    required this.rowCount,
    required this.columnCount,
  });
}

class BinaryProtocolParser {
  static const int magic = 0x4F444243;
  static const int headerSize = 16;

  static ParsedRowBuffer parse(Uint8List data) {
    if (data.length < headerSize) {
      throw FormatException('Buffer too small for header');
    }

    final reader = _BufferReader(data);

    final readMagic = reader.readUint32();
    if (readMagic != magic) {
      throw FormatException(
          'Invalid magic number: 0x${readMagic.toRadixString(16)}');
    }

    final version = reader.readUint16();
    if (version != 1) {
      throw FormatException('Unsupported version: $version');
    }

    final columnCount = reader.readUint16();
    final rowCount = reader.readUint32();
    reader.readUint32();

    final columns = <ColumnMetadata>[];
    for (int i = 0; i < columnCount; i++) {
      final odbcType = reader.readUint16();
      final nameLen = reader.readUint16();
      final name = reader.readString(nameLen);
      columns.add(ColumnMetadata(name: name, odbcType: odbcType));
    }

    final rows = <List<dynamic>>[];
    for (int r = 0; r < rowCount; r++) {
      final row = <dynamic>[];
      for (int c = 0; c < columnCount; c++) {
        final isNull = reader.readUint8();
        if (isNull == 1) {
          row.add(null);
        } else {
          final dataLen = reader.readUint32();
          final data = reader.readBytes(dataLen);
          row.add(_convertData(data, columns[c].odbcType));
        }
      }
      rows.add(row);
    }

    return ParsedRowBuffer(
      columns: columns,
      rows: rows,
      rowCount: rowCount,
      columnCount: columnCount,
    );
  }

  static dynamic _convertData(Uint8List data, int odbcType) {
    switch (odbcType) {
      case 1:
        return String.fromCharCodes(data);
      case 2:
        if (data.length >= 4) {
          final byteData = ByteData.sublistView(data);
          return byteData.getInt32(0, Endian.little);
        }
        return String.fromCharCodes(data);
      case 3:
        if (data.length >= 8) {
          final byteData = ByteData.sublistView(data);
          return byteData.getInt64(0, Endian.little);
        }
        return String.fromCharCodes(data);
      default:
        return String.fromCharCodes(data);
    }
  }
}

class _BufferReader {
  final Uint8List _data;
  int _offset = 0;

  _BufferReader(this._data);

  int readUint8() {
    return _data[_offset++];
  }

  int readUint16() {
    final value = _data.buffer.asByteData().getUint16(_offset, Endian.little);
    _offset += 2;
    return value;
  }

  int readUint32() {
    final value = _data.buffer.asByteData().getUint32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  String readString(int length) {
    final bytes = _data.sublist(_offset, _offset + length);
    _offset += length;
    return String.fromCharCodes(bytes);
  }

  Uint8List readBytes(int length) {
    final bytes = _data.sublist(_offset, _offset + length);
    _offset += length;
    return bytes;
  }
}

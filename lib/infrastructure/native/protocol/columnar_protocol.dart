import 'dart:typed_data';

class ColumnarColumnMetadata {
  final String name;
  final int odbcType;
  final bool compressed;
  final int compressionType;
  final Uint8List data;

  const ColumnarColumnMetadata({
    required this.name,
    required this.odbcType,
    required this.compressed,
    required this.compressionType,
    required this.data,
  });
}

class ParsedColumnarBuffer {
  final int version;
  final int flags;
  final int columnCount;
  final int rowCount;
  final bool compressionEnabled;
  final List<ColumnarColumnMetadata> columns;

  const ParsedColumnarBuffer({
    required this.version,
    required this.flags,
    required this.columnCount,
    required this.rowCount,
    required this.compressionEnabled,
    required this.columns,
  });
}

class ColumnarProtocolParser {
  static const int magic = 0x4F444243;
  static const int versionV2 = 2;

  static ParsedColumnarBuffer parse(Uint8List data) {
    final reader = _BufferReader(data);

    final magicValue = reader.readUint32();
    if (magicValue != magic) {
      throw FormatException('Invalid magic number: $magicValue');
    }

    final version = reader.readUint16();
    if (version != versionV2) {
      throw FormatException('Unsupported version: $version');
    }

    final flags = reader.readUint16();
    final columnCount = reader.readUint16();
    final rowCount = reader.readUint32();
    final compressionEnabled = reader.readUint8() != 0;
    reader.readUint32();

    final columns = <ColumnarColumnMetadata>[];

    for (int i = 0; i < columnCount; i++) {
      final odbcType = reader.readUint16();
      final nameLen = reader.readUint16();
      final nameBytes = reader.readBytes(nameLen);
      final name = String.fromCharCodes(nameBytes);

      final compressed = reader.readUint8() != 0;
      int compressionType = 0;
      if (compressed) {
        compressionType = reader.readUint8();
      }

      final dataSize = reader.readUint32();
      final columnData = reader.readBytes(dataSize);

      columns.add(ColumnarColumnMetadata(
        name: name,
        odbcType: odbcType,
        compressed: compressed,
        compressionType: compressionType,
        data: Uint8List.fromList(columnData),
      ));
    }

    return ParsedColumnarBuffer(
      version: version,
      flags: flags,
      columnCount: columnCount,
      rowCount: rowCount,
      compressionEnabled: compressionEnabled,
      columns: columns,
    );
  }

  static List<List<dynamic>> decodeRows(ParsedColumnarBuffer buffer) {
    final rows = <List<dynamic>>[];

    for (int rowIdx = 0; rowIdx < buffer.rowCount; rowIdx++) {
      rows.add(<dynamic>[]);
    }

    for (final column in buffer.columns) {
      final data = column.compressed
          ? _decompress(column.data, column.compressionType)
          : column.data;

      final reader = _BufferReader(data);

      for (int rowIdx = 0; rowIdx < buffer.rowCount; rowIdx++) {
        final isNull = reader.readUint8() != 0;

        if (isNull) {
          rows[rowIdx].add(null);
        } else {
          switch (column.odbcType) {
            case 2:
              final value = reader.readInt32();
              rows[rowIdx].add(value);
              break;
            case 3:
              final value = reader.readInt64();
              rows[rowIdx].add(value);
              break;
            default:
              final len = reader.readUint32();
              final bytes = reader.readBytes(len);
              rows[rowIdx].add(String.fromCharCodes(bytes));
              break;
          }
        }
      }
    }

    return rows;
  }

  static Uint8List _decompress(Uint8List data, int compressionType) {
    throw UnimplementedError('Decompression not yet implemented in Dart');
  }
}

class _BufferReader {
  final Uint8List _data;
  int _offset = 0;

  _BufferReader(this._data);

  int readUint8() {
    if (_offset >= _data.length) {
      throw RangeError('Buffer overflow');
    }
    return _data[_offset++];
  }

  int readUint16() {
    final byteData = ByteData.sublistView(_data, _offset, _offset + 2);
    _offset += 2;
    return byteData.getUint16(0, Endian.little);
  }

  int readUint32() {
    final byteData = ByteData.sublistView(_data, _offset, _offset + 4);
    _offset += 4;
    return byteData.getUint32(0, Endian.little);
  }

  int readInt32() {
    final byteData = ByteData.sublistView(_data, _offset, _offset + 4);
    _offset += 4;
    return byteData.getInt32(0, Endian.little);
  }

  int readInt64() {
    final byteData = ByteData.sublistView(_data, _offset, _offset + 8);
    _offset += 8;
    return byteData.getInt64(0, Endian.little);
  }

  List<int> readBytes(int length) {
    if (_offset + length > _data.length) {
      throw RangeError('Buffer overflow');
    }
    final result = _data.sublist(_offset, _offset + length).toList();
    _offset += length;
    return result;
  }
}

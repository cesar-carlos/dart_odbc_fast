import 'dart:typed_data';

/// Metadata for a single column in a columnar format result.
///
/// Contains column name, ODBC type, compression information, and column data.
class ColumnarColumnMetadata {
  /// Creates a new [ColumnarColumnMetadata] instance.
  ///
  /// The [name] is the column name.
  /// The [odbcType] is the ODBC SQL type code.
  /// The [compressed] indicates if the column data is compressed.
  /// The [compressionType] is the compression algorithm used (if compressed).
  /// Column data as a byte buffer (compressed or uncompressed).
  const ColumnarColumnMetadata({
    required this.name,
    required this.odbcType,
    required this.compressed,
    required this.compressionType,
    required this.data,
  });

  /// Column name.
  final String name;

  /// ODBC SQL type code.
  final int odbcType;

  /// Whether the column data is compressed.
  final bool compressed;

  /// Compression algorithm type (if compressed).
  final int compressionType;

  /// Column data as a byte buffer.
  final Uint8List data;
}

/// Parsed columnar format result buffer.
///
/// Represents a query result in columnar format where data is organized
/// by columns rather than rows, potentially with compression.
class ParsedColumnarBuffer {
  /// Creates a new [ParsedColumnarBuffer] instance.
  ///
  /// The [version] is the protocol version.
  /// The [flags] contains protocol flags.
  /// The [columnCount] is the number of columns.
  /// The [rowCount] is the number of rows.
  /// The [compressionEnabled] indicates if compression is enabled.
  /// The [columns] list contains metadata and data for each column.
  const ParsedColumnarBuffer({
    required this.version,
    required this.flags,
    required this.columnCount,
    required this.rowCount,
    required this.compressionEnabled,
    required this.columns,
  });

  /// Protocol version.
  final int version;

  /// Protocol flags.
  final int flags;

  /// Number of columns in the result set.
  final int columnCount;

  /// Number of rows in the result set.
  final int rowCount;

  /// Whether compression is enabled for this buffer.
  final bool compressionEnabled;

  /// Column metadata and data for all columns.
  final List<ColumnarColumnMetadata> columns;
}

/// Parser for columnar protocol query results.
///
/// Parses binary data in columnar format (data organized by columns)
/// with optional compression support.
class ColumnarProtocolParser {
  /// Magic number identifying columnar protocol data (ASCII "ODBC").
  static const int magic = 0x4F444243;

  /// Protocol version 2.
  static const int versionV2 = 2;

  /// Parses columnar protocol data into a [ParsedColumnarBuffer].
  ///
  /// The data parameter must contain valid columnar protocol data starting
  /// with the magic number, version, flags, column count, row count, and
  /// followed by column metadata and data.
  ///
  /// Throws [FormatException] if the data is invalid or malformed.
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

    for (var i = 0; i < columnCount; i++) {
      final odbcType = reader.readUint16();
      final nameLen = reader.readUint16();
      final nameBytes = reader.readBytes(nameLen);
      final name = String.fromCharCodes(nameBytes);

      final compressed = reader.readUint8() != 0;
      var compressionType = 0;
      if (compressed) {
        compressionType = reader.readUint8();
      }

      final dataSize = reader.readUint32();
      final columnData = reader.readBytes(dataSize);

      columns.add(
        ColumnarColumnMetadata(
          name: name,
          odbcType: odbcType,
          compressed: compressed,
          compressionType: compressionType,
          data: Uint8List.fromList(columnData),
        ),
      );
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

  /// Decodes a columnar buffer into row-oriented data.
  ///
  /// Converts columnar format (data organized by columns) into
  /// row-oriented format (list of rows, each row is a list of values).
  ///
  /// Decompresses column data if necessary.
  ///
  /// Returns a list of rows, where each row is a list of dynamic values.
  static List<List<dynamic>> decodeRows(ParsedColumnarBuffer buffer) {
    final rows = <List<dynamic>>[];

    for (var rowIdx = 0; rowIdx < buffer.rowCount; rowIdx++) {
      rows.add(<dynamic>[]);
    }

    for (final column in buffer.columns) {
      final data = column.compressed
          ? _decompress(column.data, column.compressionType)
          : column.data;

      final reader = _BufferReader(data);

      for (var rowIdx = 0; rowIdx < buffer.rowCount; rowIdx++) {
        final isNull = reader.readUint8() != 0;

        if (isNull) {
          rows[rowIdx].add(null);
        } else {
          switch (column.odbcType) {
            case 2:
              final value = reader.readInt32();
              rows[rowIdx].add(value);
            case 3:
              final value = reader.readInt64();
              rows[rowIdx].add(value);
            default:
              final len = reader.readUint32();
              final bytes = reader.readBytes(len);
              rows[rowIdx].add(String.fromCharCodes(bytes));
          }
        }
      }
    }

    return rows;
  }

  /// Decompresses column data.
  ///
  /// Currently not implemented and throws [UnimplementedError].
  static Uint8List _decompress(Uint8List data, int compressionType) {
    throw UnimplementedError('Decompression not yet implemented in Dart');
  }
}

/// Internal buffer reader for parsing columnar protocol data.
///
/// Provides methods to read various data types from a byte buffer
/// with automatic offset tracking and overflow checking.
class _BufferReader {
  /// Creates a new [_BufferReader] instance.
  ///
  /// The data parameter is the byte buffer to read from.
  _BufferReader(this._data);

  final Uint8List _data;
  int _offset = 0;

  /// Reads a single unsigned 8-bit integer.
  ///
  /// Throws [RangeError] if the buffer overflows.
  int readUint8() {
    if (_offset >= _data.length) {
      throw RangeError('Buffer overflow');
    }
    return _data[_offset++];
  }

  /// Reads an unsigned 16-bit integer in little-endian format.
  int readUint16() {
    final byteData = ByteData.sublistView(_data, _offset, _offset + 2);
    _offset += 2;
    return byteData.getUint16(0, Endian.little);
  }

  /// Reads an unsigned 32-bit integer in little-endian format.
  int readUint32() {
    final byteData = ByteData.sublistView(_data, _offset, _offset + 4);
    _offset += 4;
    return byteData.getUint32(0, Endian.little);
  }

  /// Reads a signed 32-bit integer in little-endian format.
  int readInt32() {
    final byteData = ByteData.sublistView(_data, _offset, _offset + 4);
    _offset += 4;
    return byteData.getInt32(0, Endian.little);
  }

  /// Reads a signed 64-bit integer in little-endian format.
  int readInt64() {
    final byteData = ByteData.sublistView(_data, _offset, _offset + 8);
    _offset += 8;
    return byteData.getInt64(0, Endian.little);
  }

  /// Reads [length] bytes from the buffer as a list of integers.
  ///
  /// Throws [RangeError] if the buffer overflows.
  List<int> readBytes(int length) {
    if (_offset + length > _data.length) {
      throw RangeError('Buffer overflow');
    }
    final result = _data.sublist(_offset, _offset + length).toList();
    _offset += length;
    return result;
  }
}

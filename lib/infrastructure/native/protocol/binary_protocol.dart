import 'dart:typed_data';

/// Metadata for a single column in a query result.
///
/// Contains the column name and ODBC type code.
class ColumnMetadata {
  /// Creates a new [ColumnMetadata] instance.
  ///
  /// The [name] is the column name as returned from the database.
  /// The [odbcType] is the ODBC SQL type code (e.g., 1=CHAR, 2=INTEGER).
  const ColumnMetadata({
    required this.name,
    required this.odbcType,
  });

  /// Column name.
  final String name;

  /// ODBC SQL type code.
  final int odbcType;
}

/// Parsed result buffer containing rows and column metadata.
///
/// Represents a complete query result set with column information
/// and row data. Each row is a list of dynamic values.
class ParsedRowBuffer {
  /// Creates a new [ParsedRowBuffer] instance.
  ///
  /// The [columns] list contains metadata for each column.
  /// The [rows] list contains row data, where each row is a list of values.
  /// The [rowCount] is the number of rows in the result set.
  /// The [columnCount] is the number of columns in the result set.
  const ParsedRowBuffer({
    required this.columns,
    required this.rows,
    required this.rowCount,
    required this.columnCount,
  });

  /// Column metadata for all columns in the result set.
  final List<ColumnMetadata> columns;

  /// Row data, where each row is a list of dynamic values.
  final List<List<dynamic>> rows;

  /// Number of rows in the result set.
  final int rowCount;

  /// Number of columns in the result set.
  final int columnCount;
}

/// Parser for binary protocol query results.
///
/// Parses binary data returned from the native ODBC engine into
/// structured [ParsedRowBuffer] instances with column metadata and row data.
class BinaryProtocolParser {
  /// Magic number identifying binary protocol data (ASCII "ODBC").
  static const int magic = 0x4F444243;

  /// Size of the protocol header in bytes.
  static const int headerSize = 16;

  /// Parses binary protocol data into a [ParsedRowBuffer].
  ///
  /// The data parameter must contain valid binary protocol data starting
  /// with the magic number, version, column count, row count, and followed
  /// by column metadata and row data.
  ///
  /// Throws [FormatException] if the data is invalid or malformed.
  static ParsedRowBuffer parse(Uint8List data) {
    if (data.length < headerSize) {
      throw const FormatException('Buffer too small for header');
    }

    final reader = _BufferReader(data);

    final readMagic = reader.readUint32();
    if (readMagic != magic) {
      throw FormatException(
        'Invalid magic number: 0x${readMagic.toRadixString(16)}',
      );
    }

    final version = reader.readUint16();
    if (version != 1) {
      throw FormatException('Unsupported version: $version');
    }

    final columnCount = reader.readUint16();
    final rowCount = reader.readUint32();
    reader.readUint32();

    final columns = <ColumnMetadata>[];
    for (var i = 0; i < columnCount; i++) {
      final odbcType = reader.readUint16();
      final nameLen = reader.readUint16();
      final name = reader.readString(nameLen);
      columns.add(ColumnMetadata(name: name, odbcType: odbcType));
    }

    final rows = <List<dynamic>>[];
    for (var r = 0; r < rowCount; r++) {
      final row = <dynamic>[];
      for (var c = 0; c < columnCount; c++) {
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

  /// Converts binary data to a Dart value based on ODBC type.
  ///
  /// Type 1: String
  /// Type 2: 32-bit integer
  /// Type 3: 64-bit integer
  /// Default: String
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

/// Internal buffer reader for parsing binary protocol data.
///
/// Provides methods to read various data types from a byte buffer
/// with automatic offset tracking.
class _BufferReader {
  /// Creates a new [_BufferReader] instance.
  ///
  /// The data parameter is the byte buffer to read from.
  _BufferReader(this._data);

  final Uint8List _data;
  int _offset = 0;

  /// Reads a single unsigned 8-bit integer.
  int readUint8() {
    return _data[_offset++];
  }

  /// Reads an unsigned 16-bit integer in little-endian format.
  int readUint16() {
    final value = _data.buffer.asByteData().getUint16(_offset, Endian.little);
    _offset += 2;
    return value;
  }

  /// Reads an unsigned 32-bit integer in little-endian format.
  int readUint32() {
    final value = _data.buffer.asByteData().getUint32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  /// Reads a string of the specified [length] from the buffer.
  String readString(int length) {
    final bytes = _data.sublist(_offset, _offset + length);
    _offset += length;
    return String.fromCharCodes(bytes);
  }

  /// Reads [length] bytes from the buffer as a [Uint8List].
  Uint8List readBytes(int length) {
    final bytes = _data.sublist(_offset, _offset + length);
    _offset += length;
    return bytes;
  }
}

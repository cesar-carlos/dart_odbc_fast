import 'dart:convert';
import 'dart:typed_data';

/// Metadata for a single column in a query result.
///
/// Contains column name and ODBC type code.
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

  /// Column metadata (name and ODBC type).
  final List<ColumnMetadata> columns;

  /// Row data, where each row is a list of values.
  final List<List<dynamic>> rows;

  /// Number of rows in the result set.
  final int rowCount;

  /// Number of columns in the result set.
  final int columnCount;

  /// Column names in order.
  List<String> get columnNames => columns.map((c) => c.name).toList();
}

/// Parser for binary protocol query results.
///
/// Parses binary data returned from the native ODBC engine into
/// structured [ParsedRowBuffer] instances with column metadata and row data.
class BinaryProtocolParser {
  /// Magic number identifying binary protocol data (ASCII "ODBC").
  static const int magic = 0x4F444243;

  /// Size of protocol header in bytes.
  static const int headerSize = 16;

  /// Returns total message length (header + payload) from the first 16 bytes.
  /// [data] must have length >= 16. Payload size at bytes 12..16 (LE).
  static int messageLengthFromHeader(Uint8List data) {
    if (data.length < headerSize) {
      throw const FormatException('Buffer too small for header');
    }

    final byteData = ByteData.sublistView(data);
    final payloadSize = byteData.getUint32(12, Endian.little);
    return headerSize + payloadSize;
  }

  /// Parses binary protocol data into a [ParsedRowBuffer].
  ///
  /// The data parameter must contain valid binary protocol data starting
  /// with the magic number, version, column count, row count, and followed
  /// by column metadata and row data.
  ///
  /// Throws [FormatException] if the data is invalid or malformed.
  static ParsedRowBuffer parse(Uint8List data) {
    if (data.length < messageLengthFromHeader(data)) {
      throw const FormatException('Buffer too small for header');
    }

    final reader = _BufferReader(data);

    final version = reader.readUint16();
    if (version != 1) {
      throw FormatException('Unsupported protocol version: $version');
    }

    final columnCount = reader.readUint16();
    if (columnCount < 0 || columnCount > 255) {
      throw FormatException('Invalid column count: $columnCount');
    }

    final rowCount = reader.readUint32();

    final columns = <ColumnMetadata>[];
    for (var i = 0; i < columnCount; i++) {
      final nameLength = reader.readUint8();
      final name = reader.readString(nameLength);
      final odbcType = reader.readUint16();

      columns.add(
        ColumnMetadata(
          name: name,
          odbcType: odbcType,
        ),
      );
    }

    final rows = <List<dynamic>>[];
    for (var i = 0; i < rowCount; i++) {
      final rowValues = <dynamic>[];

      for (var j = 0; j < columnCount; j++) {
        final isNull = reader.readUint8() == 1;
        final type = reader.readUint8();

        switch (type) {
          case 0:
            rowValues.add(null);
          case 1:
            final length = reader.readUint32();
            if (isNull) {
              rowValues.add(null);
            } else {
              final string = reader.readString(length);
              rowValues.add(string);
            }
          case 2:
            reader.readUint32();
            rowValues.add(reader.readUint32());
          case 3:
            reader.readUint32();
            rowValues.add(reader.readUint64());
          case 4:
            reader.readUint32();
            final hasValue = reader.readUint8() == 1;
            if (hasValue) {
              final doubleValue = reader.readFloat64();
              rowValues.add(doubleValue);
            } else {
              rowValues.add(null);
            }
          case 5:
            reader.readUint32();
            rowValues.add(reader.readFloat64());
          case 6:
            reader.readUint32();
            final hasDate = reader.readUint8() == 1;
            if (hasDate) {
              final dateValue = DateTime.fromMillisecondsSinceEpoch(
                reader.readUint64(),
                isUtc: true,
              );
              rowValues.add(dateValue);
            } else {
              rowValues.add(null);
            }
          case 7:
            final length = reader.readUint32();
            rowValues.add(reader.readBinary(length));
          default:
            rowValues.add(null);
        }
      }

      rows.add(rowValues);
    }

    return ParsedRowBuffer(
      columns: columns,
      rows: rows,
      rowCount: rowCount,
      columnCount: columnCount,
    );
  }
}

class _BufferReader {
  _BufferReader(this._data);

  final Uint8List _data;
  int _offset = 0;

  int readUint8() {
    final value = _data[_offset];
    _offset += 1;
    return value;
  }

  int readUint16() {
    final value = _data.buffer.asByteData().getUint16(_offset);
    _offset += 2;
    return value;
  }

  int readUint32() {
    final value = _data.buffer.asByteData().getUint32(_offset);
    _offset += 4;
    return value;
  }

  int readUint64() {
    final value = _data.buffer.asByteData().getUint64(_offset);
    _offset += 8;
    return value;
  }

  int readInt8() {
    final value = _data.buffer.asByteData().getInt8(_offset);
    _offset += 1;
    return value;
  }

  double readFloat64() {
    final value = _data.buffer.asByteData().getFloat64(_offset);
    _offset += 8;
    return value;
  }

  String readString(int length) {
    final bytes = _data.sublist(_offset, _offset + length);
    final value = utf8.decode(bytes);
    _offset += length;
    return value;
  }

  Uint8List readBinary(int length) {
    final bytes = _data.sublist(_offset, _offset + length);
    _offset += length;
    return Uint8List.fromList(bytes);
  }
}

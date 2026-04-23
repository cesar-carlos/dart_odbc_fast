# Columnar protocol v2 — design sketch

> **Status:** **Emitter/parser not in production** — the row-major
> `binary_protocol.dart` (v1) is still the on-the-wire return format. Anchors
> exist: Rust `--features columnar-v2` (`odbc_engine::columnar_v2` constants;
> Criterion `columnar_v2_placeholder` bench) and Dart `columnar_v2_flags.dart`
> (`isLikelyColumnarV2Header`). The historical orphan Dart module was removed
> in v3.1.0; this document remains the spec.
>
> Revisit when a benchmark shows v1 is the bottleneck (see
> *If this comes back* below).

## What it does

A columnar payload (version 2) where data is laid out column-by-column rather
than row-by-row, with optional per-column compression.

Header layout (little-endian):

```
+----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+
|  magic ("ODBC")  |ver |flags|colCnt|     rowCount      |comp|   reserved |
|       u32        |u16 | u16 | u16  |        u32        |u8  |     u32    |
+----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+
```

Per column then follows:

- `u16` ODBC type code
- `u16` name length, then UTF-8 name bytes
- `u8` compressed flag; if `1`, an extra `u8` compression algorithm id
- `u32` data size; then that many bytes of (possibly compressed) column data

`ColumnarProtocolParser.parse(data)` produces a `ParsedColumnarBuffer`, and
`decodeRows(buffer)` flips it back into the row-major shape the rest of the
library uses, decompressing per column when needed (decompression itself was
never wired — `_decompress` always throws `UnimplementedError`).

## Why it was parked

1. The row-major v1 protocol covers all current consumers comfortably.
2. Compression on the Dart side requires a binding to a native compressor
   (zstd/lz4) that we do not want in the default footprint.
3. The 19-variant `OdbcType` work in v3.0 was easier to land on the row-major
   format first; columnar v2 would need to mirror the same expansion.
4. The Rust engine never grew an emitter for this format — no end-to-end test
   ever ran against it.

## If this comes back

- Add the emitter on the Rust side first, behind a `columnar-v2` cargo
  feature.
- Decide on a compression set (probably zstd only) and add the Dart binding
  via Native Assets the same way `odbc_engine.dll` is shipped.
- Mirror the 19-variant `OdbcType` decode rules from
  `binary_protocol.dart::_convertData` so the two formats stay observationally
  equivalent at the call site.
- Add a benchmark next to `bench_baselines/` that justifies the format
  switch on a representative wide query.

---

## Original code (Dart, v3.0)

The original sketch is preserved verbatim below for reference. Do **not**
re-import it under `lib/`; copy the relevant pieces into a fresh module if
the design is revived.

```dart
import 'dart:typed_data';

const Endian _littleEndian = Endian.little;

/// **EXPERIMENTAL / NOT USED**
///
/// This file implements a columnar protocol parser (version 2) with optional
/// compression, but the Rust engine does not emit this format yet.
///
/// Current production code uses `binary_protocol.dart` (version 1) exclusively.
///
/// This file is kept for future implementation but is currently orphaned code.

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
class _BufferReader {
  _BufferReader(this._data);

  final Uint8List _data;
  int _offset = 0;

  int readUint8() {
    if (_offset >= _data.length) {
      throw RangeError('Buffer overflow');
    }
    return _data[_offset++];
  }

  int readUint16() {
    final byteData = ByteData.sublistView(_data, _offset, _offset + 2);
    _offset += 2;
    return byteData.getUint16(0, _littleEndian);
  }

  int readUint32() {
    final byteData = ByteData.sublistView(_data, _offset, _offset + 4);
    _offset += 4;
    return byteData.getUint32(0, _littleEndian);
  }

  int readInt32() {
    final byteData = ByteData.sublistView(_data, _offset, _offset + 4);
    _offset += 4;
    return byteData.getInt32(0, _littleEndian);
  }

  int readInt64() {
    final byteData = ByteData.sublistView(_data, _offset, _offset + 8);
    _offset += 8;
    return byteData.getInt64(0, _littleEndian);
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
```

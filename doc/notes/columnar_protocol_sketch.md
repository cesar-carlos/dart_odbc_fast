# Columnar protocol v2 — design sketch

> **Status (2026-04):** **Default wire format is still v1 (row-major).**
> The Rust engine can emit **columnar v2** when the execution pipeline is built
> with `ExecutionEngine::with_columnar` / `use_columnar: true` — see
> `native/odbc_engine/src/engine/core/execution_engine.rs` and
> `native/odbc_engine/src/protocol/columnar_encoder.rs` (`ColumnarEncoder`).
> The Dart side decodes v2 in `binary_protocol.dart` (`_parseColumnarV2`):
> **uncompressed** column blocks are fully supported. **Per-column
> compression** (zstd/LZ4) uses the same on-disk format as
> `columnar_encoder.rs` + `protocol/compression.rs`; the Dart path resolves
> compressed column payloads via the native engine’s `odbc_columnar_decompress`
> FFI (see PENDING §1.4, `doc/Features/PENDING_IMPLEMENTATIONS.md`).
> Small anchors also live under the Cargo feature `columnar-v2` (`odbc_engine::columnar_v2` magic/version constants; `columnar_v2_placeholder` bench) and
> `lib/.../columnar_v2_flags.dart` (`isLikelyColumnarV2Header`). The historical
> standalone Dart “orphan” parser was removed in v3.1.0; the **layout** in
> this file remains the canonical description.
>
> Revisit a **default** switch to v2 when a benchmark shows v1 is the
> bottleneck (see *If this comes back* below).

## Criterion benches (local)

From `native/odbc_engine` (or `-p odbc_engine` at the repo root):

- **v1 row-major vs v2 columnar encoding** (with optional per-column zstd in the
  v2 path): `cargo bench --bench columnar_v1_v2_encode`
- **Placeholder / v2 wire constants** (smoke for the `columnar-v2` feature):
  `cargo bench --bench columnar_v2_placeholder`

Interpretation: higher throughput in the `v1` vs `v2` group is *encoder-side*
only; end-to-end gains depend on the driver and payload. Use the same
`CompressionType` ids (1 = zstd, 2 = lz4) as Dart
`columnarDecompressWithNative` / PENDING §1.4.

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

Production `BinaryProtocolParser` in `lib/.../binary_protocol.dart` performs
this decode into the same `ParsedRowBuffer` / row lists as v1. The historical
`ColumnarProtocolParser` sketch below (§Original code) is **not** imported;
keep it for reference only.

## Why v1 is still the default

1. Most workloads are fine with the row-major v1 path.
2. **Compression** is optional: engines can use columnar without compression, or
   the Dart side decompresses through the same algorithms as
   `native/odbc_engine/src/protocol/compression.rs` (zstd + lz4).
3. A full 19+ `OdbcType` pass over columnar raw blobs must stay observationally
   equivalent to `binary_protocol.dart::_convertData` for every variant you enable.
4. **Emitting** v2 in production requires opting in in the engine; wide end-to-end
   benchmarks against real drivers are still thin — grow them before flipping defaults.

## If the default were switched to v2

- Harden the emitter path in CI (opt-in: `--features` / pool tests with DSN).
- Keep compression aligned with a single set of algorithm IDs (`enum`
  `CompressionType` in `native/odbc_engine/src/protocol/columnar.rs`) in both
  Rust and Dart.
- Mirror the 19-variant `OdbcType` decode rules from
  `binary_protocol.dart::_convertData` for every type enabled in the columnar
  encoder.
- Add a benchmark (see `benches/columnar_v2_placeholder` + PENDING §1.4) on a
  representative wide query.

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

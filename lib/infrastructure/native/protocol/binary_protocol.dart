import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/columnar_decompress_ffi.dart';
import 'package:odbc_fast/infrastructure/native/protocol/odbc_type.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

const Endian _littleEndian = Endian.little;

/// Metadata for a single column in a query result.
///
/// Contains the column name and the **protocol type discriminant** (mirror
/// of the Rust `OdbcType` enum, NOT the ODBC `SQL_*` type code).
class ColumnMetadata {
  /// Creates a new [ColumnMetadata] instance.
  ///
  /// The [name] is the column name as returned from the database.
  /// The [odbcType] is the protocol discriminant (1..19); see [OdbcType]
  /// for the canonical mapping.
  const ColumnMetadata({required this.name, required this.odbcType});

  /// Column name.
  final String name;

  /// Protocol type discriminant (matches `OdbcType.discriminant`).
  final int odbcType;

  /// Typed view of [odbcType]. Unknown discriminants degrade to
  /// [OdbcType.varchar] (forward-compatible).
  OdbcType get type => OdbcType.fromDiscriminant(odbcType);
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

  /// Column names in order.
  List<String> get columnNames => columns.map((c) => c.name).toList();
}

/// A parsed ODBC binary message: row/column payload plus optional `OUT1`
/// parameter values.
class ParsedQueryMessage {
  /// Creates a new [ParsedQueryMessage] instance.
  const ParsedQueryMessage({
    required this.rowBuffer,
    this.outputParamValues = const <ParamValue>[],
    this.refCursorRowBuffers = const <ParsedRowBuffer>[],
  });

  /// Row set (v1 row-major or v2 columnar, decoded to the same shape as v1).
  final ParsedRowBuffer rowBuffer;

  /// `OUT` / `INOUT` values from an `OUT1` trailer; empty if none.
  final List<ParamValue> outputParamValues;

  /// Materialized `SYS_REFCURSOR`-style result sets from an `RC1\0` trailer
  /// (full v1 messages); empty if none. See
  /// `BinaryProtocolParser.refCursorFooterMagic`.
  final List<ParsedRowBuffer> refCursorRowBuffers;
}

/// Parser for binary protocol query results.
///
/// Parses binary data returned from the native ODBC engine into
/// structured [ParsedRowBuffer] instances with column metadata and row data.
class BinaryProtocolParser {
  /// Magic number identifying binary protocol data (ASCII "ODBC").
  static const int magic = 0x4F444243;

  /// Trailer magic for [ParamValue] output slots (`b"OUT1"`), from the Rust
  /// engine when the call used DRT1 `OUT` / `INOUT` parameters.
  /// LE u32 of the four on-wire bytes `O U T 1` (not `0x4F555431` = `1TUO`).
  static const int outputFooterMagic = 0x3154554F;

  /// Trailer for materialized ref-cursor result sets (`b"RC1\0"`), from
  /// `RowBufferEncoder::append_ref_cursor_footer` in the native encoder.
  static const int refCursorFooterMagic = 0x00314352;

  /// Row-major wire format (matches [native/.../encoder.rs] v1).
  static const int protocolVersionRowMajor = 1;

  /// Columnar wire format (matches [native/.../columnar_encoder.rs] v2).
  static const int protocolVersionColumnarV2 = 2;

  /// Size of the v1 row-major header in bytes.
  static const int headerSizeV1 = 16;

  /// Size of the v2 columnar fixed header in bytes.
  static const int headerSizeColumnarV2 = 19;

  /// Size of the protocol header in bytes (v1 — kept for call sites that
  /// pre-date columnar and `OUT1`).
  static const int headerSize = headerSizeV1;

  /// Returns total v1 **row-major** message length (header + payload) from
  /// the first 16 bytes. [data] must have length >= 16. Payload size at
  /// bytes 12..15 (LE). Not valid for v2 columnar buffers.
  static int messageLengthFromHeader(Uint8List data) {
    if (data.length < headerSizeV1) {
      throw const FormatException('Buffer too small for header');
    }
    final base = data.offsetInBytes;
    final payloadSize =
        data.buffer.asByteData().getUint32(base + 12, _littleEndian);
    return headerSizeV1 + payloadSize;
  }

  /// Parses a full buffer into rows/columns and optional `OUT1` outputs.
  ///
  /// Supports v1 row-major, v2 columnar, optional `OUT1` trailer, optional
  /// `RC1\0` ref-cursor trailer (each sub-message is a full v1 buffer).
  static ParsedQueryMessage parseWithOutputs(Uint8List data) {
    if (data.length < 6) {
      throw const FormatException('Buffer too small for version');
    }
    final readMagic = ByteData.sublistView(
      data,
      0,
      4,
    ).getUint32(0, _littleEndian);
    if (readMagic != magic) {
      throw FormatException(
        'Invalid magic number: 0x${readMagic.toRadixString(16)}',
      );
    }
    final version = ByteData.sublistView(
      data,
      4,
      6,
    ).getUint16(0, _littleEndian);

    late final ParsedRowBuffer buffer;
    late final int mainEnd;
    if (version == protocolVersionRowMajor) {
      if (data.length < headerSizeV1) {
        throw const FormatException('Buffer too small for header');
      }
      mainEnd = messageLengthFromHeader(data);
      if (data.length < mainEnd) {
        throw const FormatException('Buffer too small for payload');
      }
      buffer = _parseRowMajorV1(Uint8List.sublistView(data, 0, mainEnd));
    } else if (version == protocolVersionColumnarV2) {
      if (data.length < headerSizeColumnarV2) {
        throw const FormatException('Buffer too small for columnar v2 header');
      }
      final payloadSize =
          ByteData.sublistView(data, 15, 19).getUint32(0, _littleEndian);
      mainEnd = headerSizeColumnarV2 + payloadSize;
      if (data.length < mainEnd) {
        throw const FormatException('Buffer too small for columnar payload');
      }
      buffer = _parseColumnarV2(Uint8List.sublistView(data, 0, mainEnd));
    } else {
      throw FormatException('Unsupported protocol version: $version');
    }

    var off = mainEnd;
    final outputs = <ParamValue>[];
    off = _parseOut1IfPresent(
      data: data,
      start: off,
      outputs: outputs,
    );
    final refCursors = <ParsedRowBuffer>[];
    off = _parseRc1IfPresent(
      data: data,
      start: off,
      out: refCursors,
    );
    if (off < data.length) {
      if (data.length - off >= 4) {
        final peek = ByteData.sublistView(
          data,
          off,
          off + 4,
        ).getUint32(0, _littleEndian);
        if (peek == outputFooterMagic || peek == refCursorFooterMagic) {
          throw const FormatException(
            'Buffer too small for complete OUT1 or RC1 trailer',
          );
        }
      }
    }
    return ParsedQueryMessage(
      rowBuffer: buffer,
      outputParamValues: outputs,
      refCursorRowBuffers: refCursors,
    );
  }

  /// Parses binary protocol data into a [ParsedRowBuffer] (v1 and v2;
  /// ignores a trailing `OUT1` block if present).
  ///
  /// Throws [FormatException] if the data is invalid or malformed.
  static ParsedRowBuffer parse(Uint8List data) {
    return parseWithOutputs(data).rowBuffer;
  }

  static ParsedRowBuffer _parseRowMajorV1(Uint8List data) {
    final reader = _BufferReader(data);

    final readMagic = reader.readUint32();
    if (readMagic != magic) {
      throw FormatException(
        'Invalid magic number: 0x${readMagic.toRadixString(16)}',
      );
    }

    final version = reader.readUint16();
    if (version != protocolVersionRowMajor) {
      throw FormatException('Not a v1 buffer in _parseRowMajorV1: $version');
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
          final cellLen = reader.readUint32();
          final cellBytes = reader.readBytes(cellLen);
          row.add(_convertData(cellBytes, columns[c].odbcType));
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

  static ParsedRowBuffer _parseColumnarV2(Uint8List data) {
    if (data.length < headerSizeColumnarV2) {
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
    if (data.length < headerSizeColumnarV2 + paySize) {
      throw const FormatException('Columnar v2: truncated payload');
    }
    if (colCount == 0) {
      return const ParsedRowBuffer(
        columns: [],
        rows: [],
        rowCount: 0,
        columnCount: 0,
      );
    }
    var off = headerSizeColumnarV2;
    final end = headerSizeColumnarV2 + paySize;
    final columnMetas = <ColumnMetadata>[];
    final byCol = <List<dynamic>>[];

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
      final name = String.fromCharCodes(
        Uint8List.sublistView(data, off, off + nameLen),
      );
      off += nameLen;
      columnMetas.add(ColumnMetadata(name: name, odbcType: odbcType));

      if (off >= end) {
        throw const FormatException('Columnar v2: missing column payload');
      }
      final isCompressed = data[off++];

      final Uint8List raw;
      if (isCompressed != 0) {
        if (off + 1 + 4 > end) {
          throw const FormatException(
            'Columnar v2: compressed header truncated',
          );
        }
        final algorithm = data[off++];
        if (off + 4 > end) {
          throw const FormatException(
            'Columnar v2: compressed size truncated',
          );
        }
        final compLen = ByteData.sublistView(
          data,
          off,
          off + 4,
        ).getUint32(0, _littleEndian);
        off += 4;
        if (off + compLen > end) {
          throw const FormatException(
            'Columnar v2: compressed data truncated',
          );
        }
        final comp = Uint8List.sublistView(data, off, off + compLen);
        off += compLen;
        final decomp = columnarDecompressWithNative(comp, algorithm);
        if (decomp == null) {
          final haveApi = isColumnarNativeDecompressAvailable;
          final hint = haveApi
              ? 'odbc_columnar_decompress rejected the payload (wrong '
                  'algorithm id, corrupt data, or size mismatch).'
              : 'Native decompress symbols were not loaded. Build or deploy '
                  'odbc_engine with odbc_columnar_decompress (Windows: '
                  'odbc_engine.dll; Linux: libodbc_engine.so) — e.g. '
                  '`cd native/odbc_engine && cargo build --release`, then '
                  'run from package root or set PATH. Algorithm ids: '
                  '1=zstd, 2=lz4. See doc/notes/columnar_protocol_sketch.md '
                  'and library_loader.dart (loadOdbcLibrary).';
          final head = 'Columnar v2: native decompress failed '
              '(algorithm=$algorithm, compBytes=$compLen, '
              'odbcDecompressFfi=$haveApi). ';
          throw FormatException('$head$hint');
        }
        raw = decomp;
      } else {
        if (off + 4 > end) {
          throw const FormatException('Columnar v2: raw size truncated');
        }
        final rawLen = ByteData.sublistView(
          data,
          off,
          off + 4,
        ).getUint32(0, _littleEndian);
        off += 4;
        if (off + rawLen > end) {
          throw const FormatException('Columnar v2: raw data truncated');
        }
        raw = Uint8List.sublistView(data, off, off + rawLen);
        off += rawLen;
      }
      byCol.add(
        _parseColumnarRaw(
          odbcType: odbcType,
          raw: raw,
          rowCount: rowCount,
        ),
      );
    }
    if (off != end) {
      throw const FormatException('Columnar v2: extra bytes in column payload');
    }
    if (byCol.length != colCount) {
      throw const FormatException('Columnar v2: column list mismatch');
    }
    final rows = <List<dynamic>>[];
    for (var r = 0; r < rowCount; r++) {
      final row = <dynamic>[];
      for (var c = 0; c < colCount; c++) {
        row.add(byCol[c][r]);
      }
      rows.add(row);
    }
    return ParsedRowBuffer(
      columns: columnMetas,
      rows: rows,
      rowCount: rowCount,
      columnCount: colCount,
    );
  }

  static List<dynamic> _parseColumnarRaw({
    required int odbcType,
    required Uint8List raw,
    required int rowCount,
  }) {
    final odbc = OdbcType.fromDiscriminant(odbcType);
    var p = 0;
    final out = <dynamic>[];
    for (var i = 0; i < rowCount; i++) {
      if (p >= raw.length) {
        throw const FormatException('Columnar v2: row cells truncated');
      }
      if (odbc == OdbcType.integer) {
        final n = raw[p++];
        if (n == 1) {
          out.add(null);
        } else {
          if (p + 4 > raw.length) {
            throw const FormatException('Columnar v2: int cell truncated');
          }
          out.add(
            ByteData.sublistView(raw, p, p + 4).getInt32(0, _littleEndian),
          );
          p += 4;
        }
      } else if (odbc == OdbcType.bigInt) {
        final n = raw[p++];
        if (n == 1) {
          out.add(null);
        } else {
          if (p + 8 > raw.length) {
            throw const FormatException('Columnar v2: bigint cell truncated');
          }
          out.add(
            ByteData.sublistView(raw, p, p + 8).getInt64(0, _littleEndian),
          );
          p += 8;
        }
      } else {
        final n = raw[p++];
        if (n == 1) {
          out.add(null);
        } else {
          if (p + 4 > raw.length) {
            throw const FormatException('Columnar v2: varchar len truncated');
          }
          final bl = ByteData.sublistView(
            raw,
            p,
            p + 4,
          ).getUint32(0, _littleEndian);
          p += 4;
          if (p + bl > raw.length) {
            throw const FormatException('Columnar v2: varchar data truncated');
          }
          final bytes = Uint8List.sublistView(raw, p, p + bl);
          p += bl;
          out.add(_convertData(bytes, odbcType));
        }
      }
    }
    if (p != raw.length) {
      throw const FormatException('Columnar v2: raw not fully consumed');
    }
    if (out.length != rowCount) {
      throw const FormatException('Columnar v2: per-column row count mismatch');
    }
    return out;
  }

  /// Returns the next offset (unchanged if no `OUT1` at [start]).
  static int _parseOut1IfPresent({
    required Uint8List data,
    required int start,
    required List<ParamValue> outputs,
  }) {
    if (data.length < start + 8) {
      return start;
    }
    final m = ByteData.sublistView(
      data,
      start,
      start + 4,
    ).getUint32(0, _littleEndian);
    if (m != outputFooterMagic) {
      return start;
    }
    var p = start + 4;
    final n = ByteData.sublistView(data, p, p + 4).getUint32(0, _littleEndian);
    p += 4;
    for (var i = 0; i < n; i++) {
      final d = deserializeParamValue(data, offset: p);
      outputs.add(d.value);
      p += d.consumed;
    }
    return p;
  }

  /// Returns the next offset (unchanged if no `RC1\0` at [start]).
  static int _parseRc1IfPresent({
    required Uint8List data,
    required int start,
    required List<ParsedRowBuffer> out,
  }) {
    if (data.length < start + 8) {
      return start;
    }
    final m = ByteData.sublistView(
      data,
      start,
      start + 4,
    ).getUint32(0, _littleEndian);
    if (m != refCursorFooterMagic) {
      return start;
    }
    var p = start + 4;
    final nCursors =
        ByteData.sublistView(data, p, p + 4).getUint32(0, _littleEndian);
    p += 4;
    for (var i = 0; i < nCursors; i++) {
      if (p + 4 > data.length) {
        throw const FormatException('RC1: truncated length prefix');
      }
      final bl =
          ByteData.sublistView(data, p, p + 4).getUint32(0, _littleEndian);
      p += 4;
      if (p + bl > data.length) {
        throw const FormatException('RC1: truncated embedded message');
      }
      final inner = Uint8List.sublistView(data, p, p + bl);
      p += bl;
      out.add(_parseRowMajorV1(inner));
    }
    return p;
  }

  /// Converts binary data to a Dart value based on the protocol
  /// discriminant. See [OdbcType] for the wire layout per variant.
  ///
  /// Returns:
  /// - [int] for [OdbcType.integer], [OdbcType.bigInt]
  /// - [Uint8List] for [OdbcType.binary]
  /// - [String] (UTF-8 decoded) for everything else
  ///
  /// Invalid UTF-8 sequences are replaced with U+FFFD (the Unicode
  /// REPLACEMENT CHARACTER) instead of being silently re-interpreted as
  /// Latin-1 — see [_decodeText] for the rationale.
  static dynamic _convertData(Uint8List data, int odbcType) {
    final type = OdbcType.fromDiscriminant(odbcType);
    if (type == OdbcType.binary) {
      return Uint8List.fromList(data);
    }
    if (type == OdbcType.integer) {
      if (data.length >= 4) {
        return ByteData.sublistView(data).getInt32(0, _littleEndian);
      }
      return _decodeText(data);
    }
    if (type == OdbcType.bigInt) {
      if (data.length >= 8) {
        return ByteData.sublistView(data).getInt64(0, _littleEndian);
      }
      return _decodeText(data);
    }
    // All other variants are UTF-8 text on the wire.
    return _decodeText(data);
  }

  /// UTF-8 decoding with a malformed-sequence-tolerant fallback.
  ///
  /// The Rust engine is configured to read text columns through
  /// `SQLGetData(SQL_C_WCHAR)` (odbc-api `default-features = false`,
  /// no `narrow` feature), so the bytes that arrive here are always the
  /// driver's UTF-16 → UTF-8 transcoding of the column value. Any byte
  /// sequence that fails to decode therefore signals a real upstream
  /// problem (driver bug, mid-Unicode truncation, deliberate corruption)
  /// — **not** another encoding to be guessed.
  ///
  /// Historically this method fell back to `String.fromCharCodes(data)`,
  /// which silently re-interprets the bytes as Latin-1. That fallback
  /// caused the user-visible mojibake reported in
  /// [issue #1](https://github.com/cesar-carlos/dart_odbc_fast/issues/1):
  /// GBK bytes (when the driver was misconfigured) showed up as
  /// `"¹ÜÀíÔ±"` instead of an obviously broken `"\uFFFD\uFFFD\uFFFD"`,
  /// hiding the bug from both users and the test suite.
  ///
  /// We now use `utf8.decode(..., allowMalformed: true)` so invalid
  /// sequences become U+FFFD. The byte stream always survives a round
  /// trip, the upstream issue is no longer masked as plausible-looking
  /// Western text, and CJK / GBK regression tests can pin the contract.
  static String _decodeText(Uint8List data) {
    return utf8.decode(data, allowMalformed: true);
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
    final value = _data.buffer.asByteData().getUint16(_offset, _littleEndian);
    _offset += 2;
    return value;
  }

  /// Reads an unsigned 32-bit integer in little-endian format.
  int readUint32() {
    final value = _data.buffer.asByteData().getUint32(_offset, _littleEndian);
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

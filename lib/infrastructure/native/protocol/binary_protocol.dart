import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/helpers/typed_columnar_converter.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_cell_decode.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_columnar.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_constants.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_row_major.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_trailers.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_types.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

export 'binary_protocol_constants.dart' show BinaryProtocolConstants;
export 'binary_protocol_types.dart';

/// Parser for binary protocol query results.
///
/// Facade over row-major, columnar, and trailer sub-parsers. Use
/// [parseColumnarToTyped] for columnar wire payloads that should stay
/// column-major; [parse] / [parseWithOutputs] remain for row-major
/// [ParsedRowBuffer] backward compatibility.
class BinaryProtocolParser {
  BinaryProtocolParser._();

  static const int magic = BinaryProtocolConstants.magic;
  static const int outputFooterMagic =
      BinaryProtocolConstants.outputFooterMagic;
  static const int refCursorFooterMagic =
      BinaryProtocolConstants.refCursorFooterMagic;
  static const int protocolVersionRowMajor =
      BinaryProtocolConstants.protocolVersionRowMajor;
  static const int protocolVersionColumnarV2 =
      BinaryProtocolConstants.protocolVersionColumnarV2;
  static const int headerSizeV1 = BinaryProtocolConstants.headerSizeV1;
  static const int headerSizeColumnarV2 =
      BinaryProtocolConstants.headerSizeColumnarV2;
  static const int headerSize = BinaryProtocolConstants.headerSize;

  static int messageLengthFromHeader(Uint8List data) {
    if (data.length < 6) {
      throw const FormatException('Buffer too small for version');
    }
    final byteData = ByteData.sublistView(data);
    final version = byteData.getUint16(4, Endian.little);
    if (version == protocolVersionRowMajor) {
      if (data.length < headerSizeV1) {
        throw const FormatException('Buffer too small for header');
      }
      final payloadSize = byteData.getUint32(12, Endian.little);
      return headerSizeV1 + payloadSize;
    }
    if (version == protocolVersionColumnarV2) {
      if (data.length < headerSizeColumnarV2) {
        throw const FormatException('Buffer too small for columnar v2 header');
      }
      final payloadSize = byteData.getUint32(15, Endian.little);
      return headerSizeColumnarV2 + payloadSize;
    }
    throw FormatException('Unsupported protocol version: $version');
  }

  /// True when [data] begins with a columnar v2 header.
  static bool isColumnarV2Message(Uint8List data) {
    if (data.length < 6) return false;
    final readMagic =
        ByteData.sublistView(data, 0, 4).getUint32(0, Endian.little);
    if (readMagic != magic) return false;
    final version =
        ByteData.sublistView(data, 4, 6).getUint16(0, Endian.little);
    return version == protocolVersionColumnarV2;
  }

  static ParsedQueryMessage parseWithOutputs(
    Uint8List data, {
    bool lazyStrings = false,
  }) {
    final previousLazy = binaryProtocolLazyStringsActive;
    setBinaryProtocolLazyStrings(active: lazyStrings);
    try {
      return _parseWithOutputsInternal(data);
    } finally {
      setBinaryProtocolLazyStrings(active: previousLazy);
    }
  }

  static ParsedColumnarQueryMessage parseColumnarWithOutputs(
    Uint8List data, {
    bool lazyStrings = false,
  }) {
    final previousLazy = binaryProtocolLazyStringsActive;
    setBinaryProtocolLazyStrings(active: lazyStrings);
    try {
      return _parseColumnarWithOutputsInternal(data);
    } finally {
      setBinaryProtocolLazyStrings(active: previousLazy);
    }
  }

  /// Decodes columnar v2 wire bytes directly to [TypedColumnarResult].
  static TypedColumnarResult parseColumnarToTyped(
    Uint8List data, {
    bool lazyStrings = false,
  }) =>
      parseColumnarWithOutputs(data, lazyStrings: lazyStrings).columnarResult;

  static ParsedRowBuffer parse(Uint8List data, {bool lazyStrings = false}) {
    return parseWithOutputs(data, lazyStrings: lazyStrings).rowBuffer;
  }

  static ParsedQueryMessage _parseWithOutputsInternal(Uint8List data) {
    if (data.length < 6) {
      throw const FormatException('Buffer too small for version');
    }
    final readMagic = ByteData.sublistView(
      data,
      0,
      4,
    ).getUint32(0, Endian.little);
    if (readMagic != magic) {
      throw FormatException(
        'Invalid magic number: 0x${readMagic.toRadixString(16)}',
      );
    }
    final version = ByteData.sublistView(
      data,
      4,
      6,
    ).getUint16(0, Endian.little);

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
      buffer = parseRowMajorV1(Uint8List.sublistView(data, 0, mainEnd));
    } else if (version == protocolVersionColumnarV2) {
      if (data.length < headerSizeColumnarV2) {
        throw const FormatException('Buffer too small for columnar v2 header');
      }
      final payloadSize =
          ByteData.sublistView(data, 15, 19).getUint32(0, Endian.little);
      mainEnd = headerSizeColumnarV2 + payloadSize;
      if (data.length < mainEnd) {
        throw const FormatException('Buffer too small for columnar payload');
      }
      buffer =
          parseColumnarV2ToRowBuffer(Uint8List.sublistView(data, 0, mainEnd));
    } else {
      throw FormatException('Unsupported protocol version: $version');
    }

    var off = mainEnd;
    final outputs = <ParamValue>[];
    off = parseOut1TrailerIfPresent(
      data: data,
      start: off,
      outputs: outputs,
    );
    final refCursors = <ParsedRowBuffer>[];
    off = parseRc1TrailerIfPresent(
      data: data,
      start: off,
      out: refCursors,
    );
    _assertNoUnknownTrailers(data, off);
    return ParsedQueryMessage(
      rowBuffer: buffer,
      outputParamValues: outputs,
      refCursorRowBuffers: refCursors,
    );
  }

  static ParsedColumnarQueryMessage _parseColumnarWithOutputsInternal(
    Uint8List data,
  ) {
    if (data.length < 6) {
      throw const FormatException('Buffer too small for version');
    }
    final readMagic = ByteData.sublistView(
      data,
      0,
      4,
    ).getUint32(0, Endian.little);
    if (readMagic != magic) {
      throw FormatException(
        'Invalid magic number: 0x${readMagic.toRadixString(16)}',
      );
    }
    final version = ByteData.sublistView(
      data,
      4,
      6,
    ).getUint16(0, Endian.little);

    late final TypedColumnarResult columnar;
    late final int mainEnd;
    if (version == protocolVersionColumnarV2) {
      if (data.length < headerSizeColumnarV2) {
        throw const FormatException('Buffer too small for columnar v2 header');
      }
      final payloadSize =
          ByteData.sublistView(data, 15, 19).getUint32(0, Endian.little);
      mainEnd = headerSizeColumnarV2 + payloadSize;
      if (data.length < mainEnd) {
        throw const FormatException('Buffer too small for columnar payload');
      }
      columnar =
          parseColumnarV2ToTyped(Uint8List.sublistView(data, 0, mainEnd));
    } else if (version == protocolVersionRowMajor) {
      final msg = _parseWithOutputsInternal(data);
      return ParsedColumnarQueryMessage(
        columnarResult: _rowBufferToTypedFallback(msg.rowBuffer),
        outputParamValues: msg.outputParamValues,
        refCursorRowBuffers: msg.refCursorRowBuffers,
      );
    } else {
      throw FormatException('Unsupported protocol version: $version');
    }

    var off = mainEnd;
    final outputs = <ParamValue>[];
    off = parseOut1TrailerIfPresent(
      data: data,
      start: off,
      outputs: outputs,
    );
    final refCursors = <ParsedRowBuffer>[];
    off = parseRc1TrailerIfPresent(
      data: data,
      start: off,
      out: refCursors,
    );
    _assertNoUnknownTrailers(data, off);
    return ParsedColumnarQueryMessage(
      columnarResult: columnar,
      outputParamValues: outputs,
      refCursorRowBuffers: refCursors,
    );
  }

  static void _assertNoUnknownTrailers(Uint8List data, int off) {
    if (off < data.length) {
      if (data.length - off >= 4) {
        final peek = ByteData.sublistView(
          data,
          off,
          off + 4,
        ).getUint32(0, Endian.little);
        if (peek == outputFooterMagic || peek == refCursorFooterMagic) {
          throw const FormatException(
            'Buffer too small for complete OUT1 or RC1 trailer',
          );
        }
      }
    }
  }

  static TypedColumnarResult _rowBufferToTypedFallback(ParsedRowBuffer buffer) {
    return toTypedColumnar(
      QueryResult(
        columns: buffer.columnNames,
        columnsMetadata: buffer.columns,
        rows: buffer.rows,
        rowCount: buffer.rowCount,
      ),
    );
  }
}

import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/helpers/typed_columnar_converter.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';

/// Decodes stream wire chunks into typed columnar or row-major buffers.
class StreamChunkDecoder {
  const StreamChunkDecoder(this._parser);

  final OdbcResultParser _parser;

  /// Decodes a complete protocol message frame for columnar streaming.
  TypedColumnarResult decodeColumnarFrame(
    Uint8List frame, {
    bool lazyStrings = false,
  }) {
    if (BinaryProtocolParser.isColumnarV2Message(frame)) {
      return BinaryProtocolParser.parseColumnarToTyped(
        frame,
        lazyStrings: lazyStrings,
      );
    }
    final rowBuffer = BinaryProtocolParser.parse(
      frame,
      lazyStrings: lazyStrings,
    );
    return toTypedColumnarFromWire(
      columnNames: rowBuffer.columnNames,
      odbcDiscriminants: [
        for (final col in rowBuffer.columns) col.odbcType,
      ],
      rows: rowBuffer.rows,
    );
  }

  /// Decodes a buffer from a non-stream execute into typed columnar form.
  TypedColumnarResult? decodeExecuteBuffer(
    Uint8List? buf, {
    bool lazyStrings = false,
  }) =>
      _parser.parseBufferToTypedColumnar(buf, lazyStrings: lazyStrings);
}

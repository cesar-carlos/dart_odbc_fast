import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/protocol_byte_accumulator.dart';

/// Incrementally accumulates binary protocol bytes and yields complete frames.
class BinaryFrameAccumulator {
  BinaryFrameAccumulator({this.maxFrameBytes = defaultMaxFrameBytes});

  /// Hard ceiling for a single frame to prevent OOM from a malformed header.
  /// Matches the result-buffer ceiling used by `ConnectionOptions` (16 MB).
  /// Frames legitimately larger than this should fail loudly rather than
  /// trigger a multi-gigabyte allocation.
  static const int defaultMaxFrameBytes = 16 * 1024 * 1024;

  final int maxFrameBytes;

  final ProtocolByteAccumulator _buffer = ProtocolByteAccumulator();

  int get length => _buffer.length;

  void add(Uint8List chunk) => _buffer.add(chunk);

  Iterable<Uint8List> drainFrames() sync* {
    // Columnar v2 header is the largest supported fixed header (19 bytes).
    const maxHeaderSize = BinaryProtocolParser.headerSizeColumnarV2;
    while (length >= 6) {
      final headerPeekLen = length < maxHeaderSize ? length : maxHeaderSize;
      final headerPeek = _buffer.peek(headerPeekLen);
      final version =
          ByteData.sublistView(headerPeek, 4, 6).getUint16(0, Endian.little);
      final headerSize = switch (version) {
        BinaryProtocolParser.protocolVersionRowMajor =>
          BinaryProtocolParser.headerSizeV1,
        BinaryProtocolParser.protocolVersionColumnarV2 =>
          BinaryProtocolParser.headerSizeColumnarV2,
        _ => throw FormatException('Unsupported protocol version: $version'),
      };
      if (headerPeekLen < headerSize) {
        break;
      }
      final frameLength = BinaryProtocolParser.messageLengthFromHeader(
        headerPeekLen == headerSize
            ? headerPeek
            : Uint8List.sublistView(headerPeek, 0, headerSize),
      );
      // DoS guard: refuse to yield/allocate frames whose declared length
      // exceeds the configured ceiling. A malformed wire header could
      // otherwise force a multi-GB allocation.
      if (frameLength < headerSize || frameLength > maxFrameBytes) {
        throw FormatException(
          'Frame length $frameLength out of bounds (max $maxFrameBytes)',
        );
      }
      if (length < frameLength) {
        break;
      }

      yield _buffer.take(frameLength);
    }
  }
}

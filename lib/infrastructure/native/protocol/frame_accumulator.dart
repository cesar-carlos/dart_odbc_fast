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
    while (length >= 6) {
      final headerPrefix = _buffer.peek(6);
      final version =
          ByteData.sublistView(headerPrefix, 4, 6).getUint16(0, Endian.little);
      final headerSize = switch (version) {
        BinaryProtocolParser.protocolVersionRowMajor =>
          BinaryProtocolParser.headerSizeV1,
        BinaryProtocolParser.protocolVersionColumnarV2 =>
          BinaryProtocolParser.headerSizeColumnarV2,
        _ => throw FormatException('Unsupported protocol version: $version'),
      };
      if (length < headerSize) {
        break;
      }
      final header = _buffer.peek(headerSize);
      final frameLength = BinaryProtocolParser.messageLengthFromHeader(header);
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

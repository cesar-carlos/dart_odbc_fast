import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';

/// Incrementally accumulates binary protocol bytes and yields complete frames.
class BinaryFrameAccumulator {
  Uint8List _buffer = Uint8List(0);
  int _offset = 0;

  int get length => _buffer.length - _offset;

  void add(Uint8List chunk) {
    if (chunk.isEmpty) return;
    if (length == 0) {
      _buffer = chunk;
      _offset = 0;
      return;
    }

    final remaining = length;
    final next = Uint8List(remaining + chunk.length)
      ..setRange(0, remaining, _buffer, _offset)
      ..setAll(remaining, chunk);
    _buffer = next;
    _offset = 0;
  }

  Iterable<Uint8List> drainFrames() sync* {
    while (length >= BinaryProtocolParser.headerSize) {
      final header = Uint8List.sublistView(
        _buffer,
        _offset,
        _offset + BinaryProtocolParser.headerSize,
      );
      final frameLength = BinaryProtocolParser.messageLengthFromHeader(header);
      if (length < frameLength) {
        break;
      }

      yield Uint8List.sublistView(
        _buffer,
        _offset,
        _offset + frameLength,
      );
      _offset += frameLength;
    }

    if (_offset == _buffer.length) {
      _buffer = Uint8List(0);
      _offset = 0;
    }
  }
}

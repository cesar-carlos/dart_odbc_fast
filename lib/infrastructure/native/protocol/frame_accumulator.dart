import 'dart:collection';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';

/// Incrementally accumulates binary protocol bytes and yields complete frames.
class BinaryFrameAccumulator {
  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _headOffset = 0;
  int _length = 0;

  int get length => _length;

  void add(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _chunks.addLast(chunk);
    _length += chunk.length;
  }

  Iterable<Uint8List> drainFrames() sync* {
    while (length >= 6) {
      final headerPrefix = _peekBytes(6);
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
      final header = _peekBytes(headerSize);
      final frameLength = BinaryProtocolParser.messageLengthFromHeader(header);
      if (length < frameLength) {
        break;
      }

      yield _takeBytes(frameLength);
    }
  }

  Uint8List _peekBytes(int count) {
    if (_chunks.isEmpty || count > _length) {
      throw RangeError.range(count, 0, _length, 'count');
    }
    final first = _chunks.first;
    if (_headOffset + count <= first.length) {
      return Uint8List.sublistView(first, _headOffset, _headOffset + count);
    }
    return _copyBytes(count, consume: false);
  }

  Uint8List _takeBytes(int count) {
    if (_chunks.isEmpty || count > _length) {
      throw RangeError.range(count, 0, _length, 'count');
    }
    final first = _chunks.first;
    if (_headOffset + count <= first.length) {
      final bytes = Uint8List.sublistView(
        first,
        _headOffset,
        _headOffset + count,
      );
      _dropBytes(count);
      return bytes;
    }
    return _copyBytes(count, consume: true);
  }

  Uint8List _copyBytes(int count, {required bool consume}) {
    final out = Uint8List(count);
    var written = 0;
    var localHeadOffset = _headOffset;

    for (final chunk in _chunks) {
      final available = chunk.length - localHeadOffset;
      if (available <= 0) {
        localHeadOffset = 0;
        continue;
      }
      final take = count - written < available ? count - written : available;
      out.setRange(written, written + take, chunk, localHeadOffset);
      written += take;
      if (written == count) break;
      localHeadOffset = 0;
    }

    if (consume) {
      _dropBytes(count);
    }
    return out;
  }

  void _dropBytes(int count) {
    var remaining = count;
    while (remaining > 0) {
      final first = _chunks.first;
      final available = first.length - _headOffset;
      if (remaining < available) {
        _headOffset += remaining;
        _length -= count;
        return;
      }
      remaining -= available;
      _chunks.removeFirst();
      _headOffset = 0;
    }
    _length -= count;
  }
}

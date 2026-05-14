import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show BinaryProtocolParser;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart'
    show
        MultiResultItem,
        MultiResultItemResultSet,
        MultiResultItemRowCount,
        MultiResultParser;

const Endian _littleEndian = Endian.little;

/// Item-frame tag for a result set payload (v3.3.0 streaming wire format).
const int multiStreamItemTagResultSet = MultiResultParser.tagResultSet;

/// Item-frame tag for a row-count payload (v3.3.0 streaming wire format).
const int multiStreamItemTagRowCount = MultiResultParser.tagRowCount;

/// Incremental decoder for the streaming multi-result wire format used by
/// `odbc_stream_multi_start_batched` / `_async` (M8 in v3.3.0).
///
/// Each chunk emitted by the native engine is a (possibly partial) sequence
/// of frames:
///
/// ```text
/// [tag: u8] [len: u32 LE] [payload: len bytes]
/// ```
///
/// Callers feed raw chunks through [feed]; each call returns the items
/// completed by the new bytes. Items are surfaced as soon as their full
/// payload has arrived. Bytes belonging to a partially-received frame are
/// kept inside the decoder until the next `feed`/`flush` call.
///
/// Example:
///
/// ```dart
/// final decoder = MultiResultStreamDecoder();
/// while (stream has more) {
///   final chunk = native.streamFetch(...);
///   for (final item in decoder.feed(chunk)) {
///     // emit item to consumer
///   }
/// }
/// // Trailing bytes after EOS are an error.
/// decoder.assertExhausted();
/// ```
class MultiResultStreamDecoder {
  static const int _frameHeaderSize = 5; // tag(1) + len(4)

  Uint8List _buffer = Uint8List(0);
  int _offset = 0;

  /// Number of items decoded so far across all `feed` calls.
  int _itemsDecoded = 0;
  int get itemsDecoded => _itemsDecoded;

  /// Number of bytes currently held back inside the decoder waiting for the
  /// rest of a frame to arrive. Useful for backpressure / observability.
  int get pendingBytes => _buffer.length - _offset;

  /// Append [chunk] to the internal buffer and return any items that became
  /// fully available. The returned list may be empty if the chunk only
  /// completed part of a frame.
  ///
  /// Throws [FormatException] if a frame declares an unknown tag.
  List<MultiResultItem> feed(Uint8List chunk) {
    if (chunk.isEmpty) return const [];
    _addChunk(chunk);
    return _drainCompleteFrames();
  }

  /// Verifies that no partial frame remains buffered. Call after the engine
  /// signalled end-of-stream. Throws [FormatException] when there are
  /// trailing bytes (always indicates a wire-format bug).
  void assertExhausted() {
    if (pendingBytes > 0) {
      throw FormatException(
        'MultiResultStreamDecoder: $pendingBytes trailing bytes after '
        'end-of-stream',
      );
    }
  }

  void _addChunk(Uint8List chunk) {
    if (pendingBytes == 0) {
      _buffer = chunk;
      _offset = 0;
      return;
    }

    final remaining = pendingBytes;
    final next = Uint8List(remaining + chunk.length)
      ..setRange(0, remaining, _buffer, _offset)
      ..setAll(remaining, chunk);
    _buffer = next;
    _offset = 0;
  }

  List<MultiResultItem> _drainCompleteFrames() {
    final items = <MultiResultItem>[];

    while (true) {
      if (pendingBytes < _frameHeaderSize) break;
      final tag = _buffer[_offset];
      final len = ByteData.sublistView(_buffer, _offset + 1, _offset + 5)
          .getUint32(0, _littleEndian);
      final frameEnd = _offset + _frameHeaderSize + len;
      if (frameEnd > _buffer.length) break; // need more bytes

      final payload = Uint8List.sublistView(
        _buffer,
        _offset + _frameHeaderSize,
        frameEnd,
      );

      switch (tag) {
        case multiStreamItemTagResultSet:
          final rs = BinaryProtocolParser.parse(payload);
          items.add(MultiResultItemResultSet(rs));

        case multiStreamItemTagRowCount:
          if (len != 8) {
            throw FormatException(
              'Streaming multi-result: RowCount frame expected 8-byte '
              'payload, got $len',
            );
          }
          final rc = ByteData.sublistView(payload).getInt64(0, _littleEndian);
          items.add(MultiResultItemRowCount(rc));

        default:
          throw FormatException(
            'Streaming multi-result: unknown frame tag $tag at offset $_offset',
          );
      }
      _offset = frameEnd;
    }

    if (_offset == _buffer.length) {
      _buffer = Uint8List(0);
      _offset = 0;
    }

    _itemsDecoded += items.length;
    return items;
  }
}

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

  final BytesBuilder _buffer = BytesBuilder(copy: false);

  /// Number of items decoded so far across all `feed` calls.
  int _itemsDecoded = 0;
  int get itemsDecoded => _itemsDecoded;

  /// Number of bytes currently held back inside the decoder waiting for the
  /// rest of a frame to arrive. Useful for backpressure / observability.
  int get pendingBytes => _buffer.length;

  /// Append [chunk] to the internal buffer and return any items that became
  /// fully available. The returned list may be empty if the chunk only
  /// completed part of a frame.
  ///
  /// Throws [FormatException] if a frame declares an unknown tag.
  List<MultiResultItem> feed(Uint8List chunk) {
    if (chunk.isEmpty) return const [];
    _buffer.add(chunk);
    return _drainCompleteFrames();
  }

  /// Verifies that no partial frame remains buffered. Call after the engine
  /// signalled end-of-stream. Throws [FormatException] when there are
  /// trailing bytes (always indicates a wire-format bug).
  void assertExhausted() {
    if (_buffer.isNotEmpty) {
      throw FormatException(
        'MultiResultStreamDecoder: ${_buffer.length} trailing bytes after '
        'end-of-stream',
      );
    }
  }

  List<MultiResultItem> _drainCompleteFrames() {
    final items = <MultiResultItem>[];

    // Snapshot the buffer once and walk it; rebuild only the leftover when
    // we're done. This avoids quadratic slicing for chunky input.
    final bytes = _buffer.toBytes();
    var offset = 0;

    while (true) {
      if (bytes.length - offset < _frameHeaderSize) break;
      final tag = bytes[offset];
      final len = ByteData.sublistView(bytes, offset + 1, offset + 5)
          .getUint32(0, _littleEndian);
      final frameEnd = offset + _frameHeaderSize + len;
      if (frameEnd > bytes.length) break; // need more bytes

      final payload = Uint8List.sublistView(
        bytes,
        offset + _frameHeaderSize,
        frameEnd,
      );

      switch (tag) {
        case multiStreamItemTagResultSet:
          final rs = BinaryProtocolParser.parse(Uint8List.fromList(payload));
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
            'Streaming multi-result: unknown frame tag $tag at offset $offset',
          );
      }
      offset = frameEnd;
    }

    // Rebuild the buffer with whatever was left over.
    _buffer.clear();
    if (offset < bytes.length) {
      _buffer.add(bytes.sublist(offset));
    }

    _itemsDecoded += items.length;
    return items;
  }
}

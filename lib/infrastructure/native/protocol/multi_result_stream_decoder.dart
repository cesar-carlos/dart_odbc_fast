import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart'
    show
        MultiResultItem,
        MultiResultItemResultSet,
        MultiResultItemRowCount,
        MultiResultParser;
import 'package:odbc_fast/infrastructure/native/protocol/protocol_byte_accumulator.dart';
import 'package:odbc_fast/infrastructure/native/protocol/stream_frame_decode.dart';

/// Item-frame tag for a result set payload (v3.3.0 streaming wire format).
const int multiStreamItemTagResultSet = MultiResultParser.tagResultSet;

/// Item-frame tag for a continuation batch of the current result set (v4.2).
const int multiStreamItemTagResultSetBatch =
    MultiResultParser.tagResultSetBatch;

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
  MultiResultStreamDecoder({this.lazyStrings = false});

  static const int _frameHeaderSize = 5; // tag(1) + len(4)

  /// When true, text cells use lazy UTF-8 wrappers in decode paths.
  final bool lazyStrings;

  final ProtocolByteAccumulator _buffer = ProtocolByteAccumulator();

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
    final items = <MultiResultItem>[];

    // Most native stream chunks contain one or more complete frames. Decode
    // those directly to avoid copying the chunk into the accumulator. Only a
    // trailing partial frame needs buffered assembly.
    if (_buffer.length == 0) {
      var offset = 0;
      while (chunk.length - offset >= _frameHeaderSize) {
        final tag = chunk[offset];
        final len = _readUint32Le(chunk, offset + 1);
        final frameEnd = offset + _frameHeaderSize + len;
        if (frameEnd > chunk.length) break;

        final payload = len == 0
            ? Uint8List(0)
            : Uint8List.sublistView(chunk, offset + _frameHeaderSize, frameEnd);
        _decodeItem(items, tag, payload);
        offset = frameEnd;
      }
      if (offset < chunk.length) {
        _buffer.add(Uint8List.sublistView(chunk, offset));
      }
    } else {
      _buffer.add(chunk);
    }

    items.addAll(_drainCompleteFrames());
    _itemsDecoded += items.length;
    return items;
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

  List<MultiResultItem> _drainCompleteFrames() {
    final items = <MultiResultItem>[];

    while (_buffer.length >= _frameHeaderSize) {
      final headerView = _buffer.peek(_frameHeaderSize);
      final tag = headerView[0];
      final len = _readUint32Le(headerView, 1);
      final frameBytes = _frameHeaderSize + len;
      if (_buffer.length < frameBytes) break;

      final Uint8List payload;
      if (len == 0) {
        _buffer.drop(_frameHeaderSize);
        payload = Uint8List(0);
      } else {
        payload = _buffer.takeAfterPrefix(_frameHeaderSize, len);
      }

      _decodeItem(items, tag, payload);
    }

    return items;
  }

  void _decodeItem(
    List<MultiResultItem> items,
    int tag,
    Uint8List payload,
  ) {
    switch (tag) {
      case multiStreamItemTagResultSet:
      case multiStreamItemTagResultSetBatch:
        final rs = decodeBatchedStreamFrame(
          payload,
          lazyStrings: lazyStrings,
        );
        items.add(
          MultiResultItemResultSet(
            rs,
            isContinuationBatch: tag == multiStreamItemTagResultSetBatch,
          ),
        );

      case multiStreamItemTagRowCount:
        if (payload.length != 8) {
          throw FormatException(
            'Streaming multi-result: RowCount frame expected 8-byte '
            'payload, got ${payload.length}',
          );
        }
        final rc = _readInt64Le(payload, 0);
        items.add(MultiResultItemRowCount(rc));

      default:
        throw FormatException(
          'Streaming multi-result: unknown frame tag $tag',
        );
    }
  }
}

int _readUint32Le(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

int _readInt64Le(Uint8List bytes, int offset) {
  final low = _readUint32Le(bytes, offset);
  final high = _readUint32Le(bytes, offset + 4);
  return (high.toSigned(32) << 32) | low;
}

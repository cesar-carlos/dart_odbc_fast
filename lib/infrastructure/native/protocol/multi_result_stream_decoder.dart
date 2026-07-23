import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart'
    show
        MultiResultItem,
        MultiResultItemResultSet,
        MultiResultItemRowCount,
        MultiResultParser;
import 'package:odbc_fast/infrastructure/native/protocol/protocol_byte_accumulator.dart';
import 'package:odbc_fast/infrastructure/native/protocol/stream_frame_decode.dart';

const Endian _littleEndian = Endian.little;

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
    _buffer.add(chunk);
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

  List<MultiResultItem> _drainCompleteFrames() {
    final items = <MultiResultItem>[];

    while (_buffer.length >= _frameHeaderSize) {
      final headerView = _buffer.peek(_frameHeaderSize);
      final tag = headerView[0];
      final len = ByteData.sublistView(headerView, 1, _frameHeaderSize)
          .getUint32(0, _littleEndian);
      final frameBytes = _frameHeaderSize + len;
      if (_buffer.length < frameBytes) break;

      _buffer.drop(_frameHeaderSize);
      final payload = len == 0 ? Uint8List(0) : _buffer.take(len);

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
            'Streaming multi-result: unknown frame tag $tag',
          );
      }
    }

    _itemsDecoded += items.length;
    return items;
  }
}

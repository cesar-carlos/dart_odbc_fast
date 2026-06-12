import 'dart:collection';
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
  static const int _frameHeaderSize = 5; // tag(1) + len(4)

  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _headOffset = 0;
  int _length = 0;

  /// Number of items decoded so far across all `feed` calls.
  int _itemsDecoded = 0;
  int get itemsDecoded => _itemsDecoded;

  /// Number of bytes currently held back inside the decoder waiting for the
  /// rest of a frame to arrive. Useful for backpressure / observability.
  int get pendingBytes => _length;

  /// Append [chunk] to the internal buffer and return any items that became
  /// fully available. The returned list may be empty if the chunk only
  /// completed part of a frame.
  ///
  /// Throws [FormatException] if a frame declares an unknown tag.
  List<MultiResultItem> feed(Uint8List chunk) {
    if (chunk.isEmpty) return const [];
    _chunks.addLast(chunk);
    _length += chunk.length;
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

  Uint8List _peekLogical(int count) {
    if (_chunks.isEmpty || count > _length) {
      throw RangeError.range(count, 0, _length, 'count');
    }
    final first = _chunks.first;
    if (_headOffset + count <= first.length) {
      return Uint8List.sublistView(first, _headOffset, _headOffset + count);
    }
    return _copyLogical(count, consume: false);
  }

  Uint8List _takeLogical(int count) {
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
      _dropLogical(count);
      return bytes;
    }
    return _copyLogical(count, consume: true);
  }

  Uint8List _copyLogical(int count, {required bool consume}) {
    final out = Uint8List(count);
    var written = 0;
    var localHead = _headOffset;

    for (final chunk in _chunks) {
      final available = chunk.length - localHead;
      if (available <= 0) {
        localHead = 0;
        continue;
      }
      final take = count - written < available ? count - written : available;
      out.setRange(written, written + take, chunk, localHead);
      written += take;
      if (written == count) break;
      localHead = 0;
    }

    if (consume) {
      _dropLogical(count);
    }
    return out;
  }

  void _dropLogical(int count) {
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

  List<MultiResultItem> _drainCompleteFrames() {
    final items = <MultiResultItem>[];

    while (_length >= _frameHeaderSize) {
      final headerView = _peekLogical(_frameHeaderSize);
      final tag = headerView[0];
      final len = ByteData.sublistView(headerView, 1, _frameHeaderSize)
          .getUint32(0, _littleEndian);
      final frameBytes = _frameHeaderSize + len;
      if (_length < frameBytes) break;

      _dropLogical(_frameHeaderSize);
      final payload = len == 0 ? Uint8List(0) : _takeLogical(len);

      switch (tag) {
        case multiStreamItemTagResultSet:
        case multiStreamItemTagResultSetBatch:
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
            'Streaming multi-result: unknown frame tag $tag',
          );
      }
    }

    _itemsDecoded += items.length;
    return items;
  }
}

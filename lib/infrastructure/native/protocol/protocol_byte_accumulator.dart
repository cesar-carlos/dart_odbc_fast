import 'dart:typed_data';

/// Single reusable buffer for incremental protocol framing.
///
/// Incoming stream chunks are appended once. [take] transfers ownership of the
/// frame bytes (zero-copy view of the prior backing store) so callers that
/// retain the frame (including lazy UTF-8 string cells) keep a live buffer. The
/// accumulator allocates a fresh backing store for subsequent [add]s.
class ProtocolByteAccumulator {
  ProtocolByteAccumulator({int initialCapacity = 64 * 1024})
      : _data = Uint8List(initialCapacity);

  static const int _defaultInitialCapacity = 64 * 1024;

  Uint8List _data;
  int _length = 0;

  int get length => _length;

  void add(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _ensureCapacity(_length + chunk.length);
    _data.setRange(_length, _length + chunk.length, chunk);
    _length += chunk.length;
  }

  Uint8List peek(int count) {
    _checkRange(count);
    return Uint8List.sublistView(_data, 0, count);
  }

  /// Returns a view of the leading [count] bytes and releases them from this
  /// accumulator. The returned list keeps the previous backing store alive.
  Uint8List take(int count) {
    _checkRange(count);
    final old = _data;
    if (count == _length) {
      _data = Uint8List(_defaultInitialCapacity);
      _length = 0;
      if (count == old.length) {
        return old;
      }
      return Uint8List.sublistView(old, 0, count);
    }

    final remaining = _length - count;
    final nextCapacity = remaining < _defaultInitialCapacity
        ? _defaultInitialCapacity
        : remaining;
    final next = Uint8List(nextCapacity)..setRange(0, remaining, old, count);
    _data = next;
    _length = remaining;
    return Uint8List.sublistView(old, 0, count);
  }

  void drop(int count) => _dropLeading(count);

  void _checkRange(int count) {
    if (count > _length) {
      throw RangeError.range(count, 0, _length, 'count');
    }
  }

  void _dropLeading(int count) {
    final remaining = _length - count;
    if (remaining == 0) {
      _length = 0;
      return;
    }
    _data.setRange(0, remaining, _data, count);
    _length = remaining;
  }

  void _ensureCapacity(int needed) {
    if (needed <= _data.length) return;
    var newCap = _data.length;
    if (newCap < _defaultInitialCapacity) {
      newCap = _defaultInitialCapacity;
    }
    while (newCap < needed) {
      newCap *= 2;
    }
    final grown = Uint8List(newCap);
    if (_length > 0) {
      grown.setRange(0, _length, _data, 0);
    }
    _data = grown;
  }
}

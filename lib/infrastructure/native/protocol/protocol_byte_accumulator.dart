import 'dart:typed_data';

/// Single reusable buffer for incremental protocol framing.
///
/// Incoming stream chunks are appended once; [take] materializes a frame copy
/// before the buffer is reused on the next [add].
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

  Uint8List take(int count) {
    _checkRange(count);
    final Uint8List bytes;
    if (count == _length) {
      if (count == _data.length) {
        bytes = _data;
        _data = Uint8List(_defaultInitialCapacity);
      } else {
        bytes = Uint8List.fromList(Uint8List.sublistView(_data, 0, count));
      }
      _length = 0;
      return bytes;
    }
    bytes = Uint8List.fromList(Uint8List.sublistView(_data, 0, count));
    _dropLeading(count);
    return bytes;
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

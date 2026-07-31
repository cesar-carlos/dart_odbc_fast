import 'dart:typed_data';

/// Single reusable buffer for incremental protocol framing.
///
/// Incoming stream chunks are appended once. [take] transfers ownership of the
/// frame bytes (zero-copy view of the prior backing store) so callers that
/// retain the frame (including lazy UTF-8 string cells) keep a live buffer. The
/// accumulator allocates a fresh backing for later [add]s, preferring a small
/// free-list of fixed-capacity buffers to cut GC under sustained streaming.
class ProtocolByteAccumulator {
  ProtocolByteAccumulator({int initialCapacity = 64 * 1024})
      : _data = _acquireBacking(initialCapacity);

  static const int _defaultInitialCapacity = 64 * 1024;
  static const int _largeCapacity = 1024 * 1024;
  static const int _maxPooledDefaultBackings = 4;
  static const int _maxPooledLargeBackings = 2;

  /// Free-list of default-capacity (64 KiB) buffers.
  static final List<Uint8List> _defaultPool = <Uint8List>[];

  /// Free-list of large-capacity (1 MiB) buffers.
  static final List<Uint8List> _largePool = <Uint8List>[];

  /// Recycles fixed-capacity frames that were fully transferred by [take]
  /// once the caller drops the last reference.
  static final Finalizer<Uint8List> _recycleFinalizer =
      Finalizer<Uint8List>(offerPooledBacking);

  Uint8List _data;
  int _length = 0;

  int get length => _length;

  /// Number of buffers currently held in free-lists (for tests).
  static int get pooledBackingCount => _defaultPool.length + _largePool.length;

  /// Number of 64 KiB buffers in the default free-list (for tests).
  static int get pooledDefaultBackingCount => _defaultPool.length;

  /// Number of 1 MiB buffers in the large free-list (for tests).
  static int get pooledLargeBackingCount => _largePool.length;

  /// Clears free-lists (for tests).
  static void clearPoolForTest() {
    _defaultPool.clear();
    _largePool.clear();
  }

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
      _data = _acquireBacking(_defaultInitialCapacity);
      _length = 0;
      if (count == old.length) {
        return _handOffFullCapacity(old);
      }
      return Uint8List.sublistView(old, 0, count);
    }

    final remaining = _length - count;
    final nextCapacity = remaining < _defaultInitialCapacity
        ? _defaultInitialCapacity
        : remaining;
    final next = _acquireBacking(nextCapacity)
      ..setRange(0, remaining, old, count);
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
    // Snap past the default tier straight to 1 MiB so grown buffers can hit
    // the large free-list instead of landing on 128/256/512 KiB orphans.
    if (needed > _defaultInitialCapacity && newCap < _largeCapacity) {
      newCap = _largeCapacity;
    }
    while (newCap < needed) {
      newCap *= 2;
    }
    final grown = Uint8List(newCap);
    if (_length > 0) {
      grown.setRange(0, _length, _data, 0);
    }
    final abandoned = _data;
    _data = grown;
    // Abandoned fixed-tier backings are no longer referenced.
    offerPooledBacking(abandoned);
  }

  /// Hands off a full-capacity backing. For pooled sizes, returns a view so
  /// the Finalizer token (backing) differs from the watched value (view).
  static Uint8List _handOffFullCapacity(Uint8List buffer) {
    if (!_isPooledCapacity(buffer.length)) {
      return buffer;
    }
    final view = Uint8List.sublistView(buffer, 0, buffer.length);
    _recycleFinalizer.attach(view, buffer);
    return view;
  }

  static bool _isPooledCapacity(int capacity) =>
      capacity == _defaultInitialCapacity || capacity == _largeCapacity;

  static Uint8List _acquireBacking(int capacity) {
    if (capacity == _defaultInitialCapacity && _defaultPool.isNotEmpty) {
      return _defaultPool.removeLast();
    }
    if (capacity == _largeCapacity && _largePool.isNotEmpty) {
      return _largePool.removeLast();
    }
    return Uint8List(capacity);
  }

  /// Offers a fixed-capacity empty buffer back to the matching free-list.
  ///
  /// Only exact 64 KiB / 1 MiB buffers are recycled so other grown
  /// allocations cannot pin large heaps in the pool.
  static void offerPooledBacking(Uint8List buffer) {
    if (buffer.length == _defaultInitialCapacity) {
      if (_defaultPool.length >= _maxPooledDefaultBackings) return;
      if (_defaultPool.contains(buffer)) return;
      _defaultPool.add(buffer);
      return;
    }
    if (buffer.length == _largeCapacity) {
      if (_largePool.length >= _maxPooledLargeBackings) return;
      if (_largePool.contains(buffer)) return;
      _largePool.add(buffer);
    }
  }

  /// Alias kept for callers/tests that recycle default-capacity frames.
  static void offerDefaultBacking(Uint8List buffer) =>
      offerPooledBacking(buffer);
}

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
      Finalizer<Uint8List>((backing) {
    _frameOwners.remove(backing.buffer);
    offerPooledBacking(backing);
  });

  static final Map<ByteBuffer, WeakReference<Uint8List>> _frameOwners = {};

  /// Keeps the sole handed-off frame alive while a lazy cell uses a slice.
  static Uint8List? retainFrame(Uint8List slice) =>
      _frameOwners[slice.buffer]?.target;

  /// Public binary views can outlive their parent; exclude their backing
  /// from automatic recycling before exposing them.
  static void protectBacking(Uint8List slice) {
    final owner = _frameOwners.remove(slice.buffer)?.target;
    if (owner != null) _recycleFinalizer.detach(owner);
  }

  static void _watchFrame(Uint8List view, Uint8List backing) {
    _frameOwners[backing.buffer] = WeakReference(view);
    _recycleFinalizer.attach(view, backing, detach: view);
  }

  Uint8List _data;
  int _length = 0;
  int _read = 0;
  bool _shared = false;
  int _views = 0;

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
    _data.setRange(_read + _length, _read + _length + chunk.length, chunk);
    _length += chunk.length;
  }

  Uint8List peek(int count) {
    _checkRange(count);
    _shared = true;
    _views++;
    return Uint8List.sublistView(_data, _read, _read + count);
  }

  /// Returns a view of the leading [count] bytes and releases them from this
  /// accumulator. The returned list keeps the previous backing store alive.
  Uint8List take(int count) {
    _checkRange(count);
    return _consume(0, count);
  }

  /// Consumes a header and returns a stable view of the payload.
  Uint8List takeAfterPrefix(int prefix, int count) {
    if (prefix < 0 || count < 0 || prefix + count > _length) {
      throw RangeError.range(prefix + count, 0, _length, 'prefix + count');
    }
    return _consume(prefix, count);
  }

  Uint8List _consume(int prefix, int count) {
    final start = _read + prefix;
    final end = start + count;
    final old = _data;
    final view = Uint8List.sublistView(old, start, end);
    _views++;
    _shared = true;
    _read = end;
    _length -= prefix + count;
    if (_length == 0) {
      // A finalizer on one view cannot recycle backing still used by others.
      if (_views == 1 && end == old.length && start == prefix) {
        if (prefix == 0) {
          if (_isPooledCapacity(old.length)) _watchFrame(view, old);
          _resetBacking();
          return view;
        }
        _watchFrame(view, old);
      }
      _resetBacking();
    }
    return view;
  }

  static final _emptyBacking = Uint8List(0);

  void _resetBacking() {
    _data = _emptyBacking;
    _length = 0;
    _read = 0;
    _shared = false;
    _views = 0;
  }

  void drop(int count) => _dropLeading(count);

  void _checkRange(int count) {
    if (count < 0 || count > _length) {
      throw RangeError.range(count, 0, _length, 'count');
    }
  }

  void _dropLeading(int count) {
    _checkRange(count);
    _read += count;
    _length -= count;
    if (_length == 0 && !_shared) _read = 0;
  }

  void _ensureCapacity(int needed) {
    if (!_shared && _read + needed <= _data.length) return;
    if (!_shared && needed <= _data.length) {
      _data.setRange(0, _length, _data, _read);
      _read = 0;
      return;
    }
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
    final grown = _acquireBacking(newCap);
    if (_length > 0) {
      grown.setRange(0, _length, _data, _read);
    }
    final abandoned = _data;
    _data = grown;
    // Abandoned fixed-tier backings are no longer referenced.
    if (!_shared) offerPooledBacking(abandoned);
    _read = 0;
    _shared = false;
    _views = 0;
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

import 'dart:collection';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:odbc_fast/infrastructure/native/bindings/odbc_bindings.dart'
    as bindings;

/// LRU cache of native UTF-8 pointers keyed by their original Dart [String].
///
/// Eliminates the per-call `toNativeUtf8` + `malloc.free` round-trip when the
/// same SQL string is executed repeatedly (hot loops, prepared statement
/// rewrite paths, etc.). Cache hits return the previously-allocated pointer
/// directly; misses allocate, register, and return.
///
/// ## Lifecycle
///
/// - The pointer is owned by the cache. Callers MUST NOT free it.
/// - When an entry is evicted (because [maxSize] was reached), its pointer is
///   freed via `malloc.free`.
/// - [dispose] releases every cached pointer; call once when the owning
///   `OdbcNative` is disposed.
///
/// ## Concurrency
///
/// Each `OdbcNative` owns its own cache, and the FFI mutex serializes calls
/// through a single connection. Sharing one cache across isolates would
/// require explicit synchronization and is not the intended design.
///
/// ## Sizing
///
/// Default 256 entries × average ~512 bytes per SQL ≈ 128 KB. Workloads with
/// larger SQL or wider hot sets should pass a custom [maxSize].
class SqlPointerCache {
  SqlPointerCache({this.maxSize = _defaultMaxSize});

  static const int _defaultMaxSize = 256;

  /// Maximum number of cached entries. Once full, the oldest entry is freed
  /// to make room for the new one (LRU policy via [LinkedHashMap] insertion
  /// order).
  final int maxSize;

  final LinkedHashMap<String, ffi.Pointer<bindings.Utf8>> _entries =
      LinkedHashMap<String, ffi.Pointer<bindings.Utf8>>();

  int _hits = 0;
  int _misses = 0;
  int _evictions = 0;

  /// Returns a native UTF-8 pointer for [sql], allocating if necessary.
  ///
  /// Refreshes the LRU position on hit so frequently-used SQL never gets
  /// evicted while a colder string holds a slot. The returned pointer
  /// remains valid until the entry is evicted or [dispose] runs.
  ffi.Pointer<bindings.Utf8> acquire(String sql) {
    final cached = _entries.remove(sql);
    if (cached != null) {
      _entries[sql] = cached;
      _hits++;
      return cached;
    }
    _misses++;

    final ptr = sql.toNativeUtf8().cast<bindings.Utf8>();
    if (_entries.length >= maxSize) {
      final oldestKey = _entries.keys.first;
      final oldestPtr = _entries.remove(oldestKey)!;
      malloc.free(oldestPtr.cast<Utf8>());
      _evictions++;
    }
    _entries[sql] = ptr;
    return ptr;
  }

  /// Frees every cached pointer. Safe to call multiple times. The cache is
  /// reusable after dispose if a new instance is constructed.
  void dispose() {
    for (final ptr in _entries.values) {
      malloc.free(ptr.cast<Utf8>());
    }
    _entries.clear();
  }

  /// Number of entries currently held by the cache.
  int get length => _entries.length;

  /// Whether the cache contains an entry for [sql].
  bool containsSql(String sql) => _entries.containsKey(sql);

  /// Diagnostic counters since construction. Useful for benchmarks and
  /// regression tests; do not export through telemetry without rolling.
  ({int hits, int misses, int evictions}) get stats => (
        hits: _hits,
        misses: _misses,
        evictions: _evictions,
      );

  /// Resets the diagnostic counters without touching the cached entries.
  void resetStats() {
    _hits = 0;
    _misses = 0;
    _evictions = 0;
  }
}

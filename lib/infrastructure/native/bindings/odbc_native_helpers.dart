part of 'odbc_native.dart';

mixin _OdbcNativeHelpers on _OdbcNativeState {
  void _requireResultEncodingSupport({
    required ResultEncoding resultEncoding,
    required bool supported,
    required String symbol,
  }) {
    if (resultEncoding != ResultEncoding.rowMajor && !supported) {
      throw UnsupportedFeatureError(
        message: 'ResultEncoding.${resultEncoding.name} requires native '
            'symbol $symbol. Upgrade odbc_engine or use '
            'ResultEncoding.rowMajor.',
      );
    }
  }

  void _requireResultEncodingWireSupport({
    required int resultEncodingWire,
    required bool supported,
    required String symbol,
  }) {
    if (resultEncodingWire != 0 && !supported) {
      throw UnsupportedFeatureError(
        message: 'Non-row-major ResultEncoding (wire=$resultEncodingWire) '
            'requires native symbol $symbol. Upgrade odbc_engine or use '
            'ResultEncoding.rowMajor.',
      );
    }
  }

  /// Shared scratch for params and mid-size bulk payloads (per isolate).
  static const int _byteScratchCapacity = 256 * 1024;

  ffi.Pointer<ffi.Uint8> _byteScratch = ffi.nullptr;
  var _byteScratchBusy = false;

  /// Reused out-param for bulk insert row counts (per isolate).
  ffi.Pointer<ffi.Uint32> _bulkRowsInserted = ffi.nullptr;

  ffi.Pointer<ffi.Uint8> _allocUint8List(Uint8List list) {
    final p = malloc<ffi.Uint8>(list.length);
    p.asTypedList(list.length).setAll(0, list);
    return p;
  }

  ffi.Pointer<ffi.Uint32> _bulkRowsInsertedPtr() {
    if (_bulkRowsInserted == ffi.nullptr) {
      _bulkRowsInserted = malloc<ffi.Uint32>();
    }
    return _bulkRowsInserted;
  }

  T? _withSql<T>(
    String sql,
    T? Function(ffi.Pointer<bindings.Utf8> ptr) f,
  ) {
    // Pointer is owned by `_sqlCache`. Caller MUST NOT free it here; the
    // cache releases on eviction or on `dispose()`. This trades a tiny,
    // bounded memory footprint (max 256 SQL strings) for elimination of
    // `toNativeUtf8 + malloc.free` on every repeat call.
    final ptr = _sqlCache.acquire(sql);
    return f(ptr);
  }

  /// Copies [bytes] into a reusable scratch (≤256 KiB) or a transient malloc.
  T? _withByteBuffer<T>(
    Uint8List bytes,
    T? Function(ffi.Pointer<ffi.Uint8> ptr) f,
  ) {
    if (bytes.isEmpty) {
      return f(ffi.nullptr);
    }
    if (bytes.length <= _byteScratchCapacity && !_byteScratchBusy) {
      if (_byteScratch == ffi.nullptr) {
        _byteScratch = malloc<ffi.Uint8>(_byteScratchCapacity);
      }
      _byteScratchBusy = true;
      try {
        _byteScratch.asTypedList(bytes.length).setAll(0, bytes);
        return f(_byteScratch);
      } finally {
        _byteScratchBusy = false;
      }
    }
    final ptr = _allocUint8List(bytes);
    try {
      return f(ptr);
    } finally {
      malloc.free(ptr);
    }
  }

  T? _withParamsBuffer<T>(
    Uint8List params,
    T? Function(ffi.Pointer<ffi.Uint8> ptr) f,
  ) =>
      _withByteBuffer(params, f);

  void _releaseParamsScratch() {
    if (_byteScratch != ffi.nullptr) {
      malloc.free(_byteScratch);
      _byteScratch = ffi.nullptr;
    }
    _byteScratchBusy = false;
    if (_bulkRowsInserted != ffi.nullptr) {
      malloc.free(_bulkRowsInserted);
      _bulkRowsInserted = ffi.nullptr;
    }
  }

  T? _withUtf8Pair<T>(
    String a,
    String b,
    T? Function(
      ffi.Pointer<bindings.Utf8> aPtr,
      ffi.Pointer<bindings.Utf8> bPtr,
    ) f,
  ) {
    // Owned by `_sqlCache` — same contract as [_withSql].
    final aPtr = _sqlCache.acquire(a);
    final bPtr = _sqlCache.acquire(b);
    return f(aPtr, bPtr);
  }

  T? _withConn<T>(int connId, T? Function(int) f) => f(connId);
}

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

  static const int _paramsScratchCapacity = 8 * 1024;

  ffi.Pointer<ffi.Uint8> _paramsScratch = ffi.nullptr;
  var _paramsScratchBusy = false;

  ffi.Pointer<ffi.Uint8> _allocUint8List(Uint8List list) {
    final p = malloc<ffi.Uint8>(list.length);
    p.asTypedList(list.length).setAll(0, list);
    return p;
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

  T? _withParamsBuffer<T>(
    Uint8List params,
    T? Function(ffi.Pointer<ffi.Uint8> ptr) f,
  ) {
    if (params.isEmpty) {
      return f(ffi.nullptr);
    }
    if (params.length <= _paramsScratchCapacity && !_paramsScratchBusy) {
      if (_paramsScratch == ffi.nullptr) {
        _paramsScratch = malloc<ffi.Uint8>(_paramsScratchCapacity);
      }
      _paramsScratchBusy = true;
      try {
        _paramsScratch.asTypedList(params.length).setAll(0, params);
        return f(_paramsScratch);
      } finally {
        _paramsScratchBusy = false;
      }
    }
    final ptr = _allocUint8List(params);
    try {
      return f(ptr);
    } finally {
      malloc.free(ptr);
    }
  }

  void _releaseParamsScratch() {
    if (_paramsScratch != ffi.nullptr) {
      malloc.free(_paramsScratch);
      _paramsScratch = ffi.nullptr;
    }
    _paramsScratchBusy = false;
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

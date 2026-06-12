part of 'odbc_native.dart';

mixin _OdbcNativeHelpers on _OdbcNativeState {
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
    final ptr = _allocUint8List(params);
    try {
      return f(ptr);
    } finally {
      malloc.free(ptr);
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
    final aPtr = a.toNativeUtf8();
    final bPtr = b.toNativeUtf8();
    try {
      return f(
        aPtr.cast<bindings.Utf8>(),
        bPtr.cast<bindings.Utf8>(),
      );
    } finally {
      malloc
        ..free(aPtr)
        ..free(bPtr);
    }
  }

  T? _withConn<T>(int connId, T? Function(int) f) => f(connId);
}

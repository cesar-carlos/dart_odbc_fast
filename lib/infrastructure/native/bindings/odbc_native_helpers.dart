part of 'odbc_native.dart';

mixin _OdbcNativeHelpers on _OdbcNativeState {
  /// Borrows [list] for the duration of a synchronous native call.
  ///
  /// The pointer is only valid while [list] remains reachable and the FFI call
  /// does not return; do not store it past the callback.
  ffi.Pointer<ffi.Uint8> _borrowUint8List(Uint8List list) {
    if (list.isEmpty) {
      return ffi.Pointer<ffi.Uint8>.fromAddress(0);
    }
    return list.address.cast<ffi.Uint8>();
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
  ) =>
      f(_borrowUint8List(params));

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

part of 'odbc_bindings.dart';

mixin _OdbcBindingsPool on _OdbcBindingsState {
  void _bindPool() {
    _odbc_pool_create_ptr = _dylib.lookup('odbc_pool_create');
    try {
      _odbc_pool_create_with_options_ptr = _dylib.lookup(
        'odbc_pool_create_with_options',
      );
    } on Object catch (_) {
      _odbc_pool_create_with_options_ptr = null;
    }
    _odbc_pool_get_connection_ptr = _dylib.lookup('odbc_pool_get_connection');
    _odbc_pool_release_connection_ptr =
        _dylib.lookup('odbc_pool_release_connection');
    _odbc_pool_health_check_ptr = _dylib.lookup('odbc_pool_health_check');
    _odbc_pool_get_state_ptr = _dylib.lookup('odbc_pool_get_state');
    _odbc_pool_get_state_json_ptr = _dylib.lookup('odbc_pool_get_state_json');
    _odbc_pool_set_size_ptr = _dylib.lookup('odbc_pool_set_size');
    _odbc_pool_close_ptr = _dylib.lookup('odbc_pool_close');
  }

  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_create_func>>
      _odbc_pool_create_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_pool_create_with_options_func>>?
      _odbc_pool_create_with_options_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_get_connection_func>>
      _odbc_pool_get_connection_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_release_connection_func>>
      _odbc_pool_release_connection_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_health_check_func>>
      _odbc_pool_health_check_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_get_state_func>>
      _odbc_pool_get_state_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_get_state_json_func>>
      _odbc_pool_get_state_json_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_set_size_func>>
      _odbc_pool_set_size_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_pool_close_func>>
      _odbc_pool_close_ptr;

  int odbc_pool_create(ffi.Pointer<Utf8> connStr, int maxSize) =>
      _odbc_pool_create_ptr.asFunction<int Function(ffi.Pointer<Utf8>, int)>()(
        connStr,
        maxSize,
      );

  bool get supportsPoolCreateWithOptions =>
      _odbc_pool_create_with_options_ptr != null;

  int odbc_pool_create_with_options(
    ffi.Pointer<Utf8> connStr,
    int maxSize,
    ffi.Pointer<Utf8>? optionsJson,
  ) {
    final ptr = _odbc_pool_create_with_options_ptr;
    if (ptr == null) return 0;
    final optsPtr = optionsJson ?? ffi.Pointer<Utf8>.fromAddress(0);
    final fn = ptr
        .asFunction<int Function(ffi.Pointer<Utf8>, int, ffi.Pointer<Utf8>)>();
    return fn(connStr, maxSize, optsPtr);
  }

  int odbc_pool_get_connection(int poolId) =>
      _odbc_pool_get_connection_ptr.asFunction<int Function(int)>()(poolId);

  int odbc_pool_release_connection(int connectionId) =>
      _odbc_pool_release_connection_ptr
          .asFunction<int Function(int)>()(connectionId);

  int odbc_pool_health_check(int poolId) =>
      _odbc_pool_health_check_ptr.asFunction<int Function(int)>()(poolId);

  int odbc_pool_get_state(
    int poolId,
    ffi.Pointer<ffi.Uint32> outSize,
    ffi.Pointer<ffi.Uint32> outIdle,
  ) =>
      _odbc_pool_get_state_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint32>,
          )>()(
        poolId,
        outSize,
        outIdle,
      );

  int odbc_pool_get_state_json(
    int poolId,
    ffi.Pointer<ffi.Uint8> buffer,
    int bufferLen,
    ffi.Pointer<ffi.Uint32> outWritten,
  ) =>
      _odbc_pool_get_state_json_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
          )>()(
        poolId,
        buffer,
        bufferLen,
        outWritten,
      );

  int odbc_pool_set_size(int poolId, int newMaxSize) => _odbc_pool_set_size_ptr
      .asFunction<int Function(int, int)>()(poolId, newMaxSize);

  int odbc_pool_close(int poolId) =>
      _odbc_pool_close_ptr.asFunction<int Function(int)>()(poolId);
}

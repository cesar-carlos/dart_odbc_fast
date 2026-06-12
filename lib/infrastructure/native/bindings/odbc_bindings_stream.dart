// FFI bindings mirror exported C symbol names; snake_case identifiers are
// intentional for 1:1 native API mapping.
// ignore_for_file: non_constant_identifier_names

part of 'odbc_bindings.dart';

mixin _OdbcBindingsStream on _OdbcBindingsState {
  void _bindStream() {
    _odbc_stream_start_ptr = _dylib.lookup('odbc_stream_start');
    try {
      _odbc_stream_start_async_ptr = _dylib.lookup('odbc_stream_start_async');
      _odbc_stream_multi_start_batched_ptr =
          _dylib.lookup('odbc_stream_multi_start_batched');
      _odbc_stream_multi_start_async_ptr =
          _dylib.lookup('odbc_stream_multi_start_async');
      _odbc_stream_poll_async_ptr = _dylib.lookup('odbc_stream_poll_async');
    } on Object catch (_) {
      _odbc_stream_start_async_ptr = null;
      _odbc_stream_multi_start_batched_ptr = null;
      _odbc_stream_multi_start_async_ptr = null;
      _odbc_stream_poll_async_ptr = null;
    }
    _odbc_stream_fetch_ptr = _dylib.lookup('odbc_stream_fetch');
    _odbc_stream_cancel_ptr = _dylib.lookup('odbc_stream_cancel');
    _odbc_stream_close_ptr = _dylib.lookup('odbc_stream_close');
    _odbc_stream_start_batched_ptr = _dylib.lookup('odbc_stream_start_batched');
    try {
      _odbc_stream_start_batched_options_ptr =
          _dylib.lookup('odbc_stream_start_batched_options');
    } on Object catch (_) {
      _odbc_stream_start_batched_options_ptr = null;
    }
  }

  late final ffi.Pointer<ffi.NativeFunction<odbc_stream_start_func>>
      _odbc_stream_start_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_stream_start_async_func>>?
      _odbc_stream_start_async_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_stream_multi_start_batched_func>>?
      _odbc_stream_multi_start_batched_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_stream_multi_start_async_func>>?
      _odbc_stream_multi_start_async_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_stream_poll_async_func>>?
      _odbc_stream_poll_async_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_stream_fetch_func>>
      _odbc_stream_fetch_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_stream_cancel_func>>
      _odbc_stream_cancel_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_stream_close_func>>
      _odbc_stream_close_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_stream_start_batched_func>>
      _odbc_stream_start_batched_ptr;

  ffi.Pointer<ffi.NativeFunction<odbc_stream_start_batched_options_func>>?
      _odbc_stream_start_batched_options_ptr;

  /// True when the loaded native library exports columnar batched streaming
  /// (`odbc_stream_start_batched_options`, v4.2+).
  bool get supportsStreamResultEncodingOptions =>
      _odbc_stream_start_batched_options_ptr != null;

  bool get supportsAsyncStreamApi =>
      _odbc_stream_start_async_ptr != null &&
      _odbc_stream_poll_async_ptr != null;

  /// True when the loaded native library exports
  /// `odbc_stream_multi_start_batched` (added in v3.3.0). Used by
  /// `OdbcNative.streamMultiStartBatched` to refuse silently on older
  /// binaries.

  bool get supportsMultiResultStream =>
      _odbc_stream_multi_start_batched_ptr != null;

  /// True when the loaded native library exports
  /// `odbc_transaction_begin_v2` (added in Sprint 4.1). Callers that need
  /// the `accessMode` (`READ ONLY` / `READ WRITE`) parameter should gate
  /// on this flag; older binaries silently fall back to v1, which is
  /// equivalent to always passing `accessMode = readWrite`.

  bool get supportsAsyncMultiResultStream =>
      _odbc_stream_multi_start_async_ptr != null &&
      _odbc_stream_poll_async_ptr != null;

  int odbc_stream_start(
    int connId,
    ffi.Pointer<Utf8> sql,
    int chunkSize,
  ) =>
      _odbc_stream_start_ptr
          .asFunction<int Function(int, ffi.Pointer<Utf8>, int)>()(
        connId,
        sql,
        chunkSize,
      );

  int? odbc_stream_start_async(
    int connId,
    ffi.Pointer<Utf8> sql,
    int fetchSize,
    int chunkSize,
  ) {
    final ptr = _odbc_stream_start_async_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<int Function(int, ffi.Pointer<Utf8>, int, int)>()(
      connId,
      sql,
      fetchSize,
      chunkSize,
    );
  }

  /// Starts a streaming multi-result batch in batched mode.
  /// Returns `null` if the native library predates v3.3.0.

  int? odbc_stream_multi_start_batched(
    int connId,
    ffi.Pointer<Utf8> sql,
    int chunkSize,
  ) {
    final ptr = _odbc_stream_multi_start_batched_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<int Function(int, ffi.Pointer<Utf8>, int)>()(
      connId,
      sql,
      chunkSize,
    );
  }

  /// Starts a streaming multi-result batch in async mode (poll + fetch).
  /// Returns `null` if the native library predates v3.3.0.

  int? odbc_stream_multi_start_async(
    int connId,
    ffi.Pointer<Utf8> sql,
    int chunkSize,
  ) {
    final ptr = _odbc_stream_multi_start_async_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<int Function(int, ffi.Pointer<Utf8>, int)>()(
      connId,
      sql,
      chunkSize,
    );
  }

  int? odbc_stream_poll_async(int streamId, ffi.Pointer<ffi.Int32> outStatus) {
    final ptr = _odbc_stream_poll_async_ptr;
    if (ptr == null) return null;
    return ptr.asFunction<int Function(int, ffi.Pointer<ffi.Int32>)>()(
      streamId,
      outStatus,
    );
  }

  int odbc_stream_fetch(
    int streamId,
    ffi.Pointer<ffi.Uint8> outBuf,
    int bufLen,
    ffi.Pointer<ffi.Uint32> outWritten,
    ffi.Pointer<ffi.Uint8> hasMore,
  ) =>
      _odbc_stream_fetch_ptr.asFunction<
          int Function(
            int,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint8>,
          )>()(streamId, outBuf, bufLen, outWritten, hasMore);

  int odbc_stream_cancel(int streamId) =>
      _odbc_stream_cancel_ptr.asFunction<int Function(int)>()(streamId);

  int odbc_stream_close(int streamId) =>
      _odbc_stream_close_ptr.asFunction<int Function(int)>()(streamId);

  int odbc_stream_start_batched(
    int connId,
    ffi.Pointer<Utf8> sql,
    int fetchSize,
    int chunkSize,
  ) =>
      _odbc_stream_start_batched_ptr
          .asFunction<int Function(int, ffi.Pointer<Utf8>, int, int)>()(
        connId,
        sql,
        fetchSize,
        chunkSize,
      );

  int? odbc_stream_start_batched_options(
    int connId,
    ffi.Pointer<Utf8> sql,
    int fetchSize,
    int chunkSize,
    int resultEncoding,
  ) {
    final ptr = _odbc_stream_start_batched_options_ptr;
    if (ptr == null) return null;
    return ptr
        .asFunction<int Function(int, ffi.Pointer<Utf8>, int, int, int)>()(
      connId,
      sql,
      fetchSize,
      chunkSize,
      resultEncoding,
    );
  }
}

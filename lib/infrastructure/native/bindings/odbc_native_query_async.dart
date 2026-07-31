part of 'odbc_native.dart';

/// Reused async poll status out-param (one per isolate process lifetime).
final ffi.Pointer<ffi.Int32> _asyncPollStatus = malloc<ffi.Int32>();

mixin _OdbcNativeQueryAsync on _OdbcNativeState, _OdbcNativeHelpers {
  /// Starts non-blocking query execution and returns async request ID.
  ///
  /// Returns `null` when API is unavailable. Returns `0` on native failure.
  int? executeAsyncStart(int connectionId, String sql) {
    if (!_bindings.supportsAsyncExecuteApi) {
      return null;
    }
    return _withSql<int>(
      sql,
      (sqlPtr) => _bindings.odbc_execute_async(connectionId, sqlPtr),
    );
  }

  /// Starts non-blocking parameterized query execution.
  ///
  /// Returns `null` when API is unavailable. Returns `0` on native failure.
  int? executeAsyncStartParams(
    int connectionId,
    String sql,
    Uint8List? params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) {
    if (!_bindings.supportsAsyncExecuteParamsApi) {
      return null;
    }
    _requireResultEncodingSupport(
      resultEncoding: resultEncoding,
      supported: _bindings.supportsAsyncExecuteParamsOptionsApi,
      symbol: 'odbc_execute_async_params_options',
    );
    return _withSql(
      sql,
      (sqlPtr) {
        if (_bindings.supportsAsyncExecuteParamsOptionsApi) {
          final wire = resultEncoding.wireCode;
          if (params == null || params.isEmpty) {
            return _bindings.odbc_execute_async_params_options(
              connectionId,
              sqlPtr,
              ffi.nullptr.cast<ffi.Uint8>(),
              0,
              wire,
            );
          }
          return _withParamsBuffer(
            params,
            (paramsPtr) => _bindings.odbc_execute_async_params_options(
              connectionId,
              sqlPtr,
              paramsPtr,
              params.length,
              wire,
            ),
          );
        }
        if (params == null || params.isEmpty) {
          return _bindings.odbc_execute_async_params(
            connectionId,
            sqlPtr,
            ffi.nullptr.cast<ffi.Uint8>(),
            0,
          );
        }
        return _withParamsBuffer(
          params,
          (paramsPtr) => _bindings.odbc_execute_async_params(
            connectionId,
            sqlPtr,
            paramsPtr,
            params.length,
          ),
        );
      },
    );
  }

  /// Polls async request status.
  ///
  /// Status values: `0` pending, `1` ready, `-1` error, `-2` cancelled.
  int? asyncPoll(int requestId) {
    if (!_bindings.supportsAsyncExecuteApi) {
      return null;
    }
    final outStatus = _asyncPollStatus..value = 0;
    final code = _bindings.odbc_async_poll(requestId, outStatus);
    if (code != 0) {
      return null;
    }
    return outStatus.value;
  }

  /// Retrieves async query result payload for a completed request.
  ///
  /// Returns null on API unavailable, request not ready, or native failure.
  Uint8List? asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
    int? initialBufferBytes,
  }) {
    if (!_bindings.supportsAsyncExecuteApi) {
      return null;
    }
    final data = callWithBuffer(
      (buf, bufLen, outWritten) =>
          _bindings.odbc_async_get_result(requestId, buf, bufLen, outWritten) ??
          -1,
      maxSize: maxBufferBytes,
      initialSize: initialBufferBytes,
    );
    if (data == null || data.isEmpty) {
      return null;
    }
    return data;
  }

  /// Best-effort cancellation for an async request.
  bool asyncCancel(int requestId) {
    if (!_bindings.supportsAsyncExecuteApi) {
      return false;
    }
    final code = _bindings.odbc_async_cancel(requestId);
    return code == 0;
  }

  /// Frees async request resources.
  bool asyncFree(int requestId) {
    if (!_bindings.supportsAsyncExecuteApi) {
      return false;
    }
    final code = _bindings.odbc_async_free(requestId);
    return code == 0;
  }
}

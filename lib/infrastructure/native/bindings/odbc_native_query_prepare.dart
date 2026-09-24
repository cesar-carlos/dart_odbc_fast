part of 'odbc_native.dart';

mixin _OdbcNativeQueryPrepare on _OdbcNativeState, _OdbcNativeHelpers {
  /// Prepares a SQL statement for execution.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement.
  /// The [timeoutMs] specifies the statement timeout in milliseconds
  /// (0 = no timeout).
  ///
  /// Returns a statement ID on success, 0 on failure.
  int prepare(int connectionId, String sql, {int timeoutMs = 0}) {
    return _withSql<int>(
          sql,
          (sqlPtr) => _bindings.odbc_prepare(connectionId, sqlPtr, timeoutMs),
        ) ??
        0;
  }

  /// Executes a prepared statement with optional binary parameters.
  ///
  /// The [stmtId] must be a valid prepared statement identifier.
  /// The [params] should be a binary buffer containing serialized parameters,
  /// or null if no parameters are needed.
  /// The [timeoutOverrideMs] overrides statement timeout (0 = use stored).
  /// The [fetchSize] specifies rows per batch (default: 1000).
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execute(
    int stmtId, [
    Uint8List? params,
    int timeoutOverrideMs = 0,
    int fetchSize = 1000,
    int? maxBufferBytes,
    int? initialBufferBytes,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  ]) {
    if (resultEncoding != ResultEncoding.rowMajor) {
      _requireResultEncodingSupport(
        resultEncoding: resultEncoding,
        supported: _bindings.supportsExecuteOptions,
        symbol: 'odbc_execute_options',
      );
    }
    int invoke(
      ffi.Pointer<ffi.Uint8> buf,
      int bufLen,
      ffi.Pointer<ffi.Uint32> outWritten,
      ffi.Pointer<ffi.Uint8>? paramsPtr,
      int paramsLen,
    ) {
      if (resultEncoding != ResultEncoding.rowMajor) {
        return _bindings.odbc_execute_options(
          stmtId,
          paramsPtr,
          paramsLen,
          timeoutOverrideMs,
          fetchSize,
          resultEncoding.wireCode,
          buf,
          bufLen,
          outWritten,
        );
      }
      return _bindings.odbc_execute(
        stmtId,
        paramsPtr,
        paramsLen,
        timeoutOverrideMs,
        fetchSize,
        buf,
        bufLen,
        outWritten,
      );
    }

    if (params == null || params.isEmpty) {
      return callWithBuffer(
        (buf, bufLen, outWritten) =>
            invoke(buf, bufLen, outWritten, ffi.nullptr, 0),
        maxSize: maxBufferBytes,
        initialSize: initialBufferBytes,
      );
    }
    return _withParamsBuffer(
      params,
      (paramsPtr) => callWithBuffer(
        (buf, bufLen, outWritten) =>
            invoke(buf, bufLen, outWritten, paramsPtr, params.length),
        maxSize: maxBufferBytes,
        initialSize: initialBufferBytes,
        preferTransient: preferTransientFfiBufferForParams(params),
      ),
    );
  }

  /// Executes a prepared statement with typed parameters.
  ///
  /// The [stmtId] must be a valid prepared statement identifier.
  /// The [params] list should contain [ParamValue] instances for each
  /// parameter placeholder, in order, or null if no parameters are needed.
  /// The [timeoutOverrideMs] overrides statement timeout (0 = use stored).
  /// The [fetchSize] specifies rows per batch (default: 1000).
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? executeTyped(
    int stmtId, [
    List<ParamValue>? params,
    int timeoutOverrideMs = 0,
    int fetchSize = 1000,
    int? maxBufferBytes,
    int? initialBufferBytes,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  ]) {
    if (params == null || params.isEmpty) {
      return execute(
        stmtId,
        null,
        timeoutOverrideMs,
        fetchSize,
        maxBufferBytes,
        initialBufferBytes,
        resultEncoding,
      );
    }
    return execute(
      stmtId,
      serializeParams(params),
      timeoutOverrideMs,
      fetchSize,
      maxBufferBytes,
      initialBufferBytes,
      resultEncoding,
    );
  }

  /// Cancels a prepared statement execution.
  ///
  /// The [stmtId] must be a valid prepared statement identifier.
  ///
  /// **Not implemented end-to-end:** the native `odbc_cancel` entry point is a
  /// stub that returns SQLSTATE `0A000` / native code `5001`. Higher layers
  /// (`IOdbcService.cancelStatement`) map that to [UnsupportedFeatureError].
  /// Prefer connection `queryTimeout` for reliable interruption.
  ///
  /// Returns true only on a successful cancel (currently never for the stub);
  /// false on failure or unsupported feature.
  bool cancelStatement(int stmtId) {
    return _bindings.odbc_cancel(stmtId) == 0;
  }

  /// Closes and releases a prepared statement.
  ///
  /// The [stmtId] must be a valid prepared statement identifier.
  /// Returns true on success, false on failure.
  bool closeStatement(int stmtId) {
    return _bindings.odbc_close_statement(stmtId) == 0;
  }

  /// Clears all prepared statements.
  ///
  /// Returns 0 on success, non-zero on failure.
  int clearAllStatements() => _bindings.odbc_clear_all_statements();
}

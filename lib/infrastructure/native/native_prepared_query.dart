part of 'native_odbc_connection.dart';

mixin _NativePreparedQuery on _NativeOdbcState {
  /// Prepares a SQL statement for execution.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement (e.g.,
  /// 'SELECT * FROM users WHERE id = ?').
  ///
  /// The [timeoutMs] specifies the statement timeout in milliseconds
  /// (0 = no timeout).
  /// Returns a statement ID on success, 0 on failure.
  int prepare(int connectionId, String sql, {int timeoutMs = 0}) =>
      _native.prepare(connectionId, sql, timeoutMs: timeoutMs);

  /// Prepares a SQL statement and returns a [PreparedStatement] wrapper.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement.
  ///
  /// The [timeoutMs] specifies the statement timeout in milliseconds
  /// (0 = no timeout).
  /// Returns a [PreparedStatement] on success, null on failure.
  PreparedStatement? prepareStatement(
    int connectionId,
    String sql, {
    int timeoutMs = 0,
  }) {
    final stmtId = prepare(connectionId, sql, timeoutMs: timeoutMs);
    if (stmtId == 0) return null;
    return PreparedStatement(_connection, stmtId);
  }

  /// Prepares a SQL statement with named parameters and returns a
  /// `PreparedStatement` wrapper that supports `executeNamed`.
  ///
  /// Supports @name and :name syntax. Converts to positional placeholders
  /// before preparing while preserving every placeholder occurrence. The
  /// returned `PreparedStatement` can use `executeNamed` with a map of
  /// parameter values, including repeated placeholder names.
  PreparedStatement? prepareStatementNamed(
    int connectionId,
    String sql, {
    int timeoutMs = 0,
  }) {
    final extractResult = NamedParameterParser.extract(sql);
    final stmtId =
        prepare(connectionId, extractResult.cleanedSql, timeoutMs: timeoutMs);
    if (stmtId == 0) return null;
    return PreparedStatement(
      _connection,
      stmtId,
      paramNamesForNamedExecution: extractResult.paramNames,
    );
  }

  Uint8List? executePrepared(
    int stmtId,
    List<ParamValue>? params,
    int timeoutOverrideMs,
    int fetchSize, {
    int? maxBufferBytes,
  }) =>
      _native.executeTyped(
        stmtId,
        params,
        timeoutOverrideMs,
        fetchSize,
        maxBufferBytes,
      );

  /// Executes a prepared statement with params already serialized (bytes).
  ///
  /// Used by the worker isolate. [serializedParams] is the output of
  /// [serializeParams] or null/empty for no params.
  Uint8List? executePreparedRaw(
    int stmtId,
    Uint8List? serializedParams,
    int timeoutOverrideMs,
    int fetchSize, {
    int? maxBufferBytes,
  }) =>
      _native.execute(
        stmtId,
        serializedParams,
        timeoutOverrideMs,
        fetchSize,
        maxBufferBytes,
      );

  /// Requests cancellation of a prepared statement execution.
  ///
  /// Returns true on success, false when cancellation fails or is unsupported.
  bool cancelStatement(int stmtId) => _native.cancelStatement(stmtId);

  bool closeStatement(int stmtId) => _native.closeStatement(stmtId);

  int clearAllStatements() => _native.clearAllStatements();

  PreparedStatementMetrics? getCacheMetrics() => _native.getCacheMetrics();

  /// Executes a SQL query with parameters.
  ///
  /// Convenience method that combines prepare and execute in a single call.
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement.
  /// The [params] list should contain [ParamValue] instances for each '?'
  /// placeholder in [sql], in order.
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? executeQueryParams(
    int connectionId,
    String sql,
    List<ParamValue> params, {
    int? maxBufferBytes,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) =>
      _native.execQueryParamsTyped(
        connectionId,
        sql,
        params,
        maxBufferBytes: maxBufferBytes,
        resultEncoding: resultEncoding,
      );

  /// Executes a parameterized query with params already serialized (bytes).
  ///
  /// Used by the worker isolate where [ParamValue] cannot be deserialized.
  /// [serializedParams] is the output of [serializeParams].
  /// When [maxBufferBytes] is set, caps the result buffer size.
  Uint8List? executeQueryParamsRaw(
    int connectionId,
    String sql,
    Uint8List? serializedParams, {
    int? maxBufferBytes,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) =>
      _native.execQueryParams(
        connectionId,
        sql,
        serializedParams,
        maxBufferBytes: maxBufferBytes,
        resultEncoding: resultEncoding,
      );

  /// Executes a SQL query that returns multiple result sets.
  ///
  /// Some databases support queries that return multiple result sets.
  /// This method handles such queries and returns the first result set.
  /// The [connectionId] must be a valid active connection.
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? executeQueryMulti(
    int connectionId,
    String sql, {
    int? maxBufferBytes,
  }) =>
      _native.execQueryMulti(connectionId, sql, maxBufferBytes: maxBufferBytes);

  /// Whether the loaded native library exports
  /// `odbc_exec_query_multi_params` (added in v3.2.0).
  bool get supportsExecuteQueryMultiParams =>
      _native.supportsExecQueryMultiParams;

  /// Whether the loaded native library exports the M8 streaming
  /// multi-result FFIs (added in v3.3.0).
  bool get supportsStreamQueryMulti => _native.supportsMultiResultStream;

  /// Starts a streaming multi-result batch in batched mode and returns the
  /// new stream id (or `null` on failure / unsupported native lib).
  /// Use `streamFetch` / `streamCancel` / `streamClose` to drive it.
  /// When [resultEncodingWire] is non-zero and the native library exports
  /// `odbc_stream_multi_start_batched_options`, result-set frames use
  /// columnar v2 wire layout.
  int? streamMultiStartBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int resultEncodingWire = 0,
  }) =>
      _native.streamMultiStartBatched(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
        resultEncodingWire: resultEncodingWire,
      );

  /// Async variant of [streamMultiStartBatched]. Combine with
  /// `streamPollAsync` for non-blocking readiness.
  int? streamMultiStartAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int resultEncodingWire = 0,
  }) =>
      _native.streamMultiStartAsync(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
        resultEncodingWire: resultEncodingWire,
      );

  /// Executes a parameterised batch SQL that may return multiple result sets.
  ///
  /// See `OdbcNative.execQueryMultiParams` for the full contract.
  /// `paramsBuffer` is the output of `serializeParams(...)`.
  Uint8List? executeQueryMultiParams(
    int connectionId,
    String sql,
    Uint8List? paramsBuffer, {
    int? maxBufferBytes,
  }) =>
      _native.execQueryMultiParams(
        connectionId,
        sql,
        paramsBuffer,
        maxBufferBytes: maxBufferBytes,
      );
}

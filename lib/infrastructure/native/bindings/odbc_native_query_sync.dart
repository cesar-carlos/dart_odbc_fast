part of 'odbc_native.dart';

mixin _OdbcNativeQuerySync on _OdbcNativeState, _OdbcNativeHelpers {
  /// Executes a SQL query and returns binary result data.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a valid SQL SELECT statement.
  /// When [maxBufferBytes] is set, caps the result buffer size; otherwise
  /// uses the package default.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execQuery(int connectionId, String sql, {int? maxBufferBytes}) {
    return _withSql(
      sql,
      (sqlPtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_exec_query(
          connectionId,
          sqlPtr,
          buf,
          bufLen,
          outWritten,
        ),
        maxSize: maxBufferBytes,
      ),
    );
  }

  /// Executes a SQL query with binary parameters.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement.
  /// The [params] should be a binary buffer containing serialized parameters.
  /// When [maxBufferBytes] is set, caps the result buffer size; otherwise
  /// uses the package default.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execQueryParams(
    int connectionId,
    String sql,
    Uint8List? params, {
    int? maxBufferBytes,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) {
    final paramsOrEmpty =
        (params == null || params.isEmpty) ? Uint8List(0) : params;
    final useOptions = resultEncoding != ResultEncoding.rowMajor &&
        _bindings.supportsExecQueryParamsOptions;
    return _withSql(
      sql,
      (sqlPtr) {
        return _withParamsBuffer(
          paramsOrEmpty,
          (paramsPtr) => callWithBuffer(
            (buf, bufLen, outWritten) => useOptions
                ? _bindings.odbc_exec_query_params_options(
                    connectionId,
                    sqlPtr,
                    paramsPtr,
                    paramsOrEmpty.length,
                    resultEncoding.wireCode,
                    buf,
                    bufLen,
                    outWritten,
                  )
                : _bindings.odbc_exec_query_params(
                    connectionId,
                    sqlPtr,
                    paramsPtr,
                    paramsOrEmpty.length,
                    buf,
                    bufLen,
                    outWritten,
                  ),
            maxSize: maxBufferBytes,
          ),
        );
      },
    );
  }

  /// Executes a SQL query with typed parameters.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [sql] should be a parameterized SQL statement.
  /// The [params] list should contain [ParamValue] instances for each
  /// parameter placeholder in [sql], in order.
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execQueryParamsTyped(
    int connectionId,
    String sql,
    List<ParamValue> params, {
    int? maxBufferBytes,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) {
    if (params.isEmpty) {
      return execQueryParams(
        connectionId,
        sql,
        null,
        maxBufferBytes: maxBufferBytes,
        resultEncoding: resultEncoding,
      );
    }
    final buf = serializeParams(params);
    return execQueryParams(
      connectionId,
      sql,
      buf,
      maxBufferBytes: maxBufferBytes,
      resultEncoding: resultEncoding,
    );
  }

  /// Executes a SQL query that returns multiple result sets.
  ///
  /// Some databases support queries that return multiple result sets.
  /// This method handles such queries and returns the first result set.
  /// The [connectionId] must be a valid active connection.
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? execQueryMulti(
    int connectionId,
    String sql, {
    int? maxBufferBytes,
  }) {
    return _withSql(
      sql,
      (sqlPtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_exec_query_multi(
          connectionId,
          sqlPtr,
          buf,
          bufLen,
          outWritten,
        ),
        maxSize: maxBufferBytes,
      ),
    );
  }

  /// Whether the loaded native library exports
  /// `odbc_exec_query_multi_params` (added in v3.2.0).
  bool get supportsExecQueryMultiParams =>
      _bindings.supportsExecQueryMultiParams;

  /// Executes a parameterised batch SQL that may return multiple result sets.
  ///
  /// Same wire format as [execQueryMulti]. The Rust engine collects every
  /// result set (cursor or row-count) the batch produces in order — see M1
  /// fix in v3.2.0.
  ///
  /// [paramsBuffer] is the output of `serializeParams(...)`. Pass `null` (or
  /// an empty buffer) for the no-params case (equivalent to [execQueryMulti]).
  /// When [maxBufferBytes] is set, caps the result buffer size.
  ///
  /// Returns binary result data on success, `null` on failure. Throws
  /// [StateError] if the loaded native library predates v3.2.0.
  Uint8List? execQueryMultiParams(
    int connectionId,
    String sql,
    Uint8List? paramsBuffer, {
    int? maxBufferBytes,
  }) {
    if (!_bindings.supportsExecQueryMultiParams) {
      throw StateError(
        'odbc_exec_query_multi_params requires odbc_engine >= 3.2.0',
      );
    }
    return _withSql(
      sql,
      (sqlPtr) => callWithBuffer(
        (buf, bufLen, outWritten) {
          final hasParams = paramsBuffer != null && paramsBuffer.isNotEmpty;
          if (hasParams) {
            final paramsLen = paramsBuffer.length;
            final paramsPtr = malloc<ffi.Uint8>(paramsLen);
            try {
              paramsPtr.asTypedList(paramsLen).setAll(0, paramsBuffer);
              return _bindings.odbc_exec_query_multi_params(
                connectionId,
                sqlPtr,
                paramsPtr,
                paramsLen,
                buf,
                bufLen,
                outWritten,
              );
            } finally {
              malloc.free(paramsPtr);
            }
          }
          return _bindings.odbc_exec_query_multi_params(
            connectionId,
            sqlPtr,
            null,
            0,
            buf,
            bufLen,
            outWritten,
          );
        },
        maxSize: maxBufferBytes,
      ),
    );
  }

  /// Gets performance and operational metrics.
  ///
  /// Returns [OdbcMetrics] containing query counts, error counts,
  /// uptime, and latency information, or null on failure.
  OdbcMetrics? getMetrics() {
    const metricsSize = 40;
    final buf = malloc<ffi.Uint8>(metricsSize);
    final outWritten = malloc<ffi.Uint32>();
    try {
      final code = _bindings.odbc_get_metrics(buf, metricsSize, outWritten);
      if (code != 0) return null;
      final n = outWritten.value;
      if (n < metricsSize) return null;
      return OdbcMetrics.fromBytes(
        Uint8List.fromList(buf.asTypedList(metricsSize)),
      );
    } finally {
      malloc
        ..free(buf)
        ..free(outWritten);
    }
  }

  /// Gets prepared statement cache metrics.
  ///
  /// Returns [PreparedStatementMetrics] on success, null on failure.
  PreparedStatementMetrics? getCacheMetrics() {
    const metricsSize = 64;
    final buf = malloc<ffi.Uint8>(metricsSize);
    final outWritten = malloc<ffi.Uint32>();
    try {
      final code =
          _bindings.odbc_get_cache_metrics(buf, metricsSize, outWritten);
      if (code != 0) return null;
      final n = outWritten.value;
      if (n < metricsSize) return null;
      return PreparedStatementMetrics.fromBytes(
        Uint8List.fromList(buf.asTypedList(metricsSize)),
      );
    } finally {
      malloc
        ..free(buf)
        ..free(outWritten);
    }
  }

  /// Clears the prepared statement cache.
  ///
  /// Returns true on success, false on failure.
  bool clearStatementCache() {
    final code = _bindings.odbc_clear_statement_cache();
    return code == 0;
  }

  /// Enables or reconfigures metadata cache in native engine.
  ///
  /// [maxEntries] and [ttlSeconds] must be greater than zero.
  /// Returns true on success.
  bool metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) {
    final code = _bindings.odbc_metadata_cache_enable(maxEntries, ttlSeconds);
    return code == 0;
  }

  /// Returns metadata cache statistics as JSON payload.
  ///
  /// Example keys: `hits`, `misses`, `size`, `max_size`, `ttl_secs`.
  /// Returns null on failure.
  String? metadataCacheStatsJson() {
    final data = callWithBuffer(
      _bindings.odbc_metadata_cache_stats,
      initialSize: 128,
    );
    if (data == null || data.isEmpty) {
      return null;
    }
    return utf8.decode(data);
  }

  /// Clears all metadata cache entries.
  ///
  /// Returns true on success.
  bool metadataCacheClear() {
    final code = _bindings.odbc_metadata_cache_clear();
    return code == 0;
  }
}

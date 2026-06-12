part of 'odbc_native.dart';

mixin _OdbcNativeQuery on _OdbcNativeState, _OdbcNativeHelpers {
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
        if (resultEncoding != ResultEncoding.rowMajor) {
          return null;
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
    final outStatus = malloc<ffi.Int32>()..value = 0;
    try {
      final code = _bindings.odbc_async_poll(requestId, outStatus);
      if (code != 0) {
        return null;
      }
      return outStatus.value;
    } finally {
      malloc.free(outStatus);
    }
  }

  /// Retrieves async query result payload for a completed request.
  ///
  /// Returns null on API unavailable, request not ready, or native failure.
  Uint8List? asyncGetResult(int requestId) {
    if (!_bindings.supportsAsyncExecuteApi) {
      return null;
    }
    final data = callWithBuffer(
      (buf, bufLen, outWritten) =>
          _bindings.odbc_async_get_result(requestId, buf, bufLen, outWritten) ??
          -1,
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

  /// Queries the database catalog for table information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [catalog] and [schema] parameters filter results.
  /// Empty strings match all values.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
  }) {
    return _withUtf8Pair(
      catalog,
      schema,
      (cPtr, sPtr) => _withConn(
        connectionId,
        (conn) => callWithBuffer(
          (buf, bufLen, outWritten) => _bindings.odbc_catalog_tables(
            conn,
            cPtr,
            sPtr,
            buf,
            bufLen,
            outWritten,
          ),
        ),
      ),
    );
  }

  /// Queries the database catalog for column information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [table] is the table name to query columns for.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? catalogColumns(int connectionId, String table) {
    return _withSql(
      table,
      (tablePtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_catalog_columns(
          connectionId,
          tablePtr,
          buf,
          bufLen,
          outWritten,
        ),
      ),
    );
  }

  /// Queries the database catalog for data type information.
  ///
  /// The [connectionId] must be a valid active connection.
  ///
  /// Returns binary result data on success, null on failure.
  Uint8List? catalogTypeInfo(int connectionId) {
    return callWithBuffer(
      (buf, bufLen, outWritten) => _bindings.odbc_catalog_type_info(
        connectionId,
        buf,
        bufLen,
        outWritten,
      ),
    );
  }

  /// Queries the database catalog for primary key information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [table] is the table name to query primary keys for.
  ///
  /// Returns binary result data on success, null on failure.
  /// Result columns: TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, CONSTRAINT_NAME
  Uint8List? catalogPrimaryKeys(int connectionId, String table) {
    return _withSql(
      table,
      (tablePtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_catalog_primary_keys(
          connectionId,
          tablePtr,
          buf,
          bufLen,
          outWritten,
        ),
      ),
    );
  }

  /// Queries the database catalog for foreign key information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [table] is the table name to query foreign keys for.
  ///
  /// Returns binary result data on success, null on failure.
  /// Result columns: CONSTRAINT_NAME, FROM_TABLE, FROM_COLUMN, TO_TABLE,
  /// TO_COLUMN, UPDATE_RULE, DELETE_RULE
  Uint8List? catalogForeignKeys(int connectionId, String table) {
    return _withSql(
      table,
      (tablePtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_catalog_foreign_keys(
          connectionId,
          tablePtr,
          buf,
          bufLen,
          outWritten,
        ),
      ),
    );
  }

  /// Queries the database catalog for index information.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [table] is the table name to query indexes for.
  ///
  /// Returns binary result data on success, null on failure.
  /// Result columns: INDEX_NAME, TABLE_NAME, COLUMN_NAME, IS_UNIQUE,
  /// IS_PRIMARY, ORDINAL_POSITION
  Uint8List? catalogIndexes(int connectionId, String table) {
    return _withSql(
      table,
      (tablePtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_catalog_indexes(
          connectionId,
          tablePtr,
          buf,
          bufLen,
          outWritten,
        ),
      ),
    );
  }

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
  ]) {
    if (params == null || params.isEmpty) {
      return callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_execute(
          stmtId,
          ffi.nullptr,
          0,
          timeoutOverrideMs,
          fetchSize,
          buf,
          bufLen,
          outWritten,
        ),
        maxSize: maxBufferBytes,
      );
    }
    return _withParamsBuffer(
      params,
      (paramsPtr) => callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_execute(
          stmtId,
          paramsPtr,
          params.length,
          timeoutOverrideMs,
          fetchSize,
          buf,
          bufLen,
          outWritten,
        ),
        maxSize: maxBufferBytes,
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
  ]) {
    if (params == null || params.isEmpty) {
      return execute(
        stmtId,
        null,
        timeoutOverrideMs,
        fetchSize,
        maxBufferBytes,
      );
    }
    return execute(
      stmtId,
      serializeParams(params),
      timeoutOverrideMs,
      fetchSize,
      maxBufferBytes,
    );
  }

  /// Cancels a prepared statement execution.
  ///
  /// The [stmtId] must be a valid prepared statement identifier.
  ///
  /// Current native contract may return unsupported feature errors depending
  /// on runtime capabilities.
  ///
  /// Returns true on success, false on failure.
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

  /// Performs a bulk insert operation.
  ///
  /// Inserts multiple rows into [table] using the specified [columns].
  /// The [dataBuffer] contains the data as a binary buffer.
  /// The [rowCount] specifies how many rows are in [dataBuffer].
  ///
  /// Returns the number of rows inserted on success, -1 on failure.
  int bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) {
    final tablePtr = table.toNativeUtf8();
    final colPtrs = malloc<ffi.Pointer<bindings.Utf8>>(columns.length);
    final utf8Ptrs = <ffi.Pointer<ffi.Opaque>>[];
    try {
      for (var i = 0; i < columns.length; i++) {
        final p = columns[i].toNativeUtf8();
        utf8Ptrs.add(p);
        (colPtrs + i).value = p.cast<bindings.Utf8>();
      }
      final rowsInserted = malloc<ffi.Uint32>();
      try {
        final code = _bindings.odbc_bulk_insert_array(
          connectionId,
          tablePtr.cast<bindings.Utf8>(),
          colPtrs,
          columns.length,
          _borrowUint8List(dataBuffer),
          dataBuffer.length,
          rowCount,
          rowsInserted,
        );
        if (code != 0) return -1;
        return rowsInserted.value;
      } finally {
        malloc.free(rowsInserted);
      }
    } finally {
      utf8Ptrs.forEach(malloc.free);
      malloc
        ..free(colPtrs)
        ..free(tablePtr);
    }
  }

  /// Performs a parallel bulk insert operation through [poolId].
  ///
  /// [dataBuffer] must be built using [BulkInsertBuilder.build()].
  /// Returns inserted row count on success, -1 on failure.
  int bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int parallelism,
  ) {
    final tablePtr = table.toNativeUtf8();
    final colPtrs = malloc<ffi.Pointer<bindings.Utf8>>(columns.length);
    final utf8Ptrs = <ffi.Pointer<ffi.Opaque>>[];
    try {
      for (var i = 0; i < columns.length; i++) {
        final p = columns[i].toNativeUtf8();
        utf8Ptrs.add(p);
        (colPtrs + i).value = p.cast<bindings.Utf8>();
      }
      final rowsInserted = malloc<ffi.Uint32>();
      try {
        final code = _bindings.odbc_bulk_insert_parallel(
          poolId,
          tablePtr.cast<bindings.Utf8>(),
          colPtrs,
          columns.length,
          _borrowUint8List(dataBuffer),
          dataBuffer.length,
          parallelism,
          rowsInserted,
        );
        if (code != 0) return -1;
        return rowsInserted.value;
      } finally {
        malloc.free(rowsInserted);
      }
    } finally {
      utf8Ptrs.forEach(malloc.free);
      malloc
        ..free(colPtrs)
        ..free(tablePtr);
    }
  }
}

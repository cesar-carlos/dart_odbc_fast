part of 'async_native_odbc_connection.dart';

mixin _AsyncQuery on _AsyncOdbcState, _AsyncWorkerDispatch, _AsyncQueryAsync {
  /// Prepares [sql] on [connectionId] in the worker.
  ///
  /// [timeoutMs] is the statement execution timeout (0 = no limit).
  /// Returns the statement ID on success.
  Future<int> prepare(int connectionId, String sql, {int timeoutMs = 0}) async {
    final r = await _sendRequest<IntResponse>(
      PrepareRequest(_nextRequestId(), connectionId, sql, timeoutMs: timeoutMs),
    );
    return r.value;
  }

  /// Prepares [sql] with named parameters on [connectionId] in the worker.
  ///
  /// Supports `@name` and `:name` syntax. Named placeholders are converted
  /// to positional placeholders before prepare. All placeholder occurrences
  /// are preserved so repeated names can reuse the same input value during
  /// execution. On success, internal metadata is stored so
  /// [executePreparedNamed] can bind values by name.
  Future<int> prepareNamed(
    int connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    final extract = NamedParameterParser.extract(sql);
    final stmtId = await prepare(
      connectionId,
      extract.cleanedSql,
      timeoutMs: timeoutMs,
    );
    if (stmtId > 0) {
      _namedParamOrderByStmtId[stmtId] = extract.paramNames;
    }
    return stmtId;
  }

  /// Executes a prepared statement [stmtId] in the worker with optional
  /// [params]. Returns the binary result, or `null` on error.
  Future<Uint8List?> executePrepared(
    int stmtId,
    List<ParamValue>? params,
    int timeoutOverrideMs,
    int fetchSize, {
    int? maxBufferBytes,
  }) async {
    final bytes =
        params == null || params.isEmpty ? null : serializeParams(params);
    final r = await _sendRequest<QueryResponse>(
      ExecutePreparedRequest(
        _nextRequestId(),
        stmtId,
        bytes ?? Uint8List(0),
        timeoutOverrideMs: timeoutOverrideMs,
        fetchSize: fetchSize,
        maxResultBufferBytes: maxBufferBytes,
      ),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Executes a prepared statement [stmtId] using named parameters.
  ///
  /// The [stmtId] must come from [prepareNamed]. Throws [AsyncError] with
  /// [AsyncErrorCode.invalidParameter] when named parameter metadata is
  /// missing or required parameters are not provided. Repeated placeholders
  /// reuse the same value from [namedParams].
  Future<Uint8List?> executePreparedNamed(
    int stmtId,
    Map<String, Object?> namedParams,
    int timeoutOverrideMs,
    int fetchSize, {
    int? maxBufferBytes,
  }) async {
    final paramOrder = _namedParamOrderByStmtId[stmtId];
    if (paramOrder == null) {
      throw const AsyncError(
        code: AsyncErrorCode.invalidParameter,
        message: 'Statement was not prepared with prepareNamed',
      );
    }

    try {
      final positional = NamedParameterParser.toPositionalParams(
        namedParams: namedParams,
        paramNames: paramOrder,
      );
      final paramValues = paramValuesFromObjects(positional);
      return executePrepared(
        stmtId,
        paramValues,
        timeoutOverrideMs,
        fetchSize,
        maxBufferBytes: maxBufferBytes,
      );
    } on ParameterMissingException catch (e) {
      throw AsyncError(
        code: AsyncErrorCode.invalidParameter,
        message: e.message,
      );
    }
  }

  /// Executes [sql] on [connectionId] with [params] in the worker.
  ///
  /// When [maxBufferBytes] is set, caps the result buffer size.
  /// Returns the binary result (same format as sync API), or `null` on error.
  Future<Uint8List?> executeQueryParams(
    int connectionId,
    String sql,
    List<ParamValue> params, {
    int? maxBufferBytes,
    Duration? timeout,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    final bytes = params.isEmpty ? Uint8List(0) : serializeParams(params);
    return executeQueryParamBuffer(
      connectionId,
      sql,
      bytes,
      maxBufferBytes: maxBufferBytes,
      timeout: timeout,
      resultEncoding: resultEncoding,
    );
  }

  Future<Uint8List?> _executeQueryParamsBlocking(
    int connectionId,
    String sql,
    Uint8List bytes, {
    int? maxBufferBytes,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    final r = await _sendRequest<QueryResponse>(
      ExecuteQueryParamsRequest(
        _nextRequestId(),
        connectionId,
        sql,
        bytes,
        maxResultBufferBytes: maxBufferBytes,
        resultEncoding: resultEncoding,
      ),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Executes a parameterised query with a pre-serialised buffer (legacy v0 or
  /// DRT1 directed parameters).
  Future<Uint8List?> executeQueryParamBuffer(
    int connectionId,
    String sql,
    Uint8List? paramBuffer, {
    int? maxBufferBytes,
    Duration? timeout,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    final bytes =
        paramBuffer == null || paramBuffer.isEmpty ? Uint8List(0) : paramBuffer;
    final asyncRequestId = await executeAsyncStartParams(
      connectionId,
      sql,
      bytes,
      resultEncoding: resultEncoding,
    );
    if (asyncRequestId > 0) {
      return _waitForAsyncResult(
        asyncRequestId,
        maxBufferBytes: maxBufferBytes,
        timeout: timeout,
      );
    }

    _recordFallbackToBlocking(connectionId);
    return _executeQueryParamsBlocking(
      connectionId,
      sql,
      bytes,
      maxBufferBytes: maxBufferBytes,
      resultEncoding: resultEncoding,
    );
  }

  /// Executes [sql] on [connectionId] using named parameters.
  ///
  /// Supports `@name` and `:name` syntax, converting placeholders to
  /// positional order before sending the query to the worker. Repeated
  /// placeholders reuse the same value from [namedParams].
  ///
  /// Throws [AsyncError] with [AsyncErrorCode.invalidParameter] when any
  /// required named parameter is missing.
  Future<Uint8List?> executeQueryNamed(
    int connectionId,
    String sql,
    Map<String, Object?> namedParams, {
    int? maxBufferBytes,
  }) async {
    try {
      final extract = NamedParameterParser.extract(sql);
      final positional = NamedParameterParser.toPositionalParams(
        namedParams: namedParams,
        paramNames: extract.paramNames,
      );
      final paramValues = paramValuesFromObjects(positional);
      return executeQueryParams(
        connectionId,
        extract.cleanedSql,
        paramValues,
        maxBufferBytes: maxBufferBytes,
      );
    } on ParameterMissingException catch (e) {
      throw AsyncError(
        code: AsyncErrorCode.invalidParameter,
        message: e.message,
      );
    }
  }

  /// Executes [sql] on [connectionId] for multi-result sets in the worker.
  /// When [maxBufferBytes] is set, caps the result buffer size.
  /// Returns the binary result, or `null` on error.
  Future<Uint8List?> executeQueryMulti(
    int connectionId,
    String sql, {
    int? maxBufferBytes,
  }) async {
    final r = await _sendRequest<QueryResponse>(
      ExecuteQueryMultiRequest(
        _nextRequestId(),
        connectionId,
        sql,
        maxResultBufferBytes: maxBufferBytes,
      ),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Executes a parameterised multi-result batch in the worker.
  ///
  /// `paramsBuffer` is the output of `serializeParams(...)`. Pass `null` for
  /// no parameters. New in v3.2.0 (M5).
  Future<Uint8List?> executeQueryMultiParams(
    int connectionId,
    String sql,
    Uint8List? paramsBuffer, {
    int? maxBufferBytes,
  }) async {
    final r = await _sendRequest<QueryResponse>(
      ExecuteQueryMultiParamsRequest(
        _nextRequestId(),
        connectionId,
        sql,
        paramsBuffer ?? Uint8List(0),
        maxResultBufferBytes: maxBufferBytes,
      ),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Requests cancellation of prepared statement [stmtId] in the worker.
  ///
  /// Returns `true` if cancellation request succeeded, `false` otherwise.
  Future<bool> cancelStatement(int stmtId) async {
    final r = await _sendRequest<BoolResponse>(
      CancelStatementRequest(_nextRequestId(), stmtId),
    );
    return r.value;
  }

  /// Closes the prepared statement [stmtId] in the worker.
  Future<bool> closeStatement(int stmtId) async {
    try {
      final r = await _sendRequest<BoolResponse>(
        CloseStatementRequest(_nextRequestId(), stmtId),
      );
      return r.value;
    } finally {
      _namedParamOrderByStmtId.remove(stmtId);
    }
  }

  Future<int> clearAllStatements() async {
    final r = await _sendRequest<IntResponse>(
      ClearAllStatementsRequest(_nextRequestId()),
    );
    if (r.value == 0) {
      _namedParamOrderByStmtId.clear();
    }
    return r.value;
  }

  /// Returns catalog tables for [connectionId] (optional [catalog] and
  /// [schema]). Returns binary result or `null` on error.
  Future<Uint8List?> catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
  }) async {
    final r = await _sendRequest<QueryResponse>(
      CatalogTablesRequest(
        _nextRequestId(),
        connectionId,
        catalog: catalog,
        schema: schema,
      ),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Returns catalog columns for [table] on [connectionId]. Binary result or
  /// `null` on error.
  Future<Uint8List?> catalogColumns(int connectionId, String table) async {
    final r = await _sendRequest<QueryResponse>(
      CatalogColumnsRequest(_nextRequestId(), connectionId, table),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Returns type info for [connectionId]. Binary result or `null` on error.
  Future<Uint8List?> catalogTypeInfo(int connectionId) async {
    final r = await _sendRequest<QueryResponse>(
      CatalogTypeInfoRequest(_nextRequestId(), connectionId),
    );
    if (r.error != null) return null;
    return r.data;
  }

  Future<Uint8List?> catalogPrimaryKeys(
    int connectionId,
    String table,
  ) async {
    final r = await _sendRequest<QueryResponse>(
      CatalogPrimaryKeysRequest(_nextRequestId(), connectionId, table),
    );
    if (r.error != null) return null;
    return r.data;
  }

  Future<Uint8List?> catalogForeignKeys(
    int connectionId,
    String table,
  ) async {
    final r = await _sendRequest<QueryResponse>(
      CatalogForeignKeysRequest(_nextRequestId(), connectionId, table),
    );
    if (r.error != null) return null;
    return r.data;
  }

  Future<Uint8List?> catalogIndexes(
    int connectionId,
    String table,
  ) async {
    final r = await _sendRequest<QueryResponse>(
      CatalogIndexesRequest(_nextRequestId(), connectionId, table),
    );
    if (r.error != null) return null;
    return r.data;
  }
}

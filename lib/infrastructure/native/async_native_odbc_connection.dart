import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/isolate/worker_isolate.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/named_parameter_parser.dart'
    show NamedParameterParser, ParameterMissingException;
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

/// Non-blocking wrapper around ODBC using a long-lived worker isolate.
///
/// **Architecture**: All FFI/ODBC operations run in a dedicated worker isolate.
/// The main thread stays responsive; no blocking FFI calls run on the UI
/// thread.
///
/// ## How it works
///
/// 1. [initialize] spawns a worker isolate and loads the ODBC driver.
/// 2. Each operation sends a request (via [SendPort]) to the worker.
/// 3. The worker runs the FFI call and sends back the result (via
///    [ReceivePort]).
/// 4. The main thread never blocks on ODBC.
///
/// ## Performance
///
/// - Worker spawn (one-time): ~50–100 ms.
/// - Per-operation overhead: ~1–3 ms.
/// - Parallel queries: N queries complete in the time of the longest (not
///   the sum).
///
/// ## Request timeout
///
/// Use `requestTimeout` to avoid UI hangs when the worker does not respond
/// (default 30s). Pass `Duration.zero` or `null` to disable.
///
/// ## Example
///
/// ```dart
/// final async = AsyncNativeOdbcConnection(
///   requestTimeout: Duration(seconds: 30),
/// );
/// await async.initialize();
///
/// final connId = await async.connect(dsn);
/// final data = await async.executeQueryParams(connId, 'SELECT 1', []);
/// await async.disconnect(connId);
///
/// async.dispose(); // Pending requests complete with error
/// ```
///
/// See also:
/// - `worker_isolate.dart` for the worker entry and request handling.
/// - [WorkerRequest] and [WorkerResponse] for the message protocol.
class AsyncNativeOdbcConnection {
  AsyncNativeOdbcConnection({
    Duration? requestTimeout,
    void Function(SendPort)? isolateEntry,
    this.autoRecoverOnWorkerCrash = false,
  })  : _requestTimeout = requestTimeout,
        _isolateEntry = isolateEntry;

  static const _defaultRequestTimeout = Duration(seconds: 30);

  final Duration? _requestTimeout;

  /// Test hook: custom isolate entry. When set, used instead of [workerEntry].
  final void Function(SendPort)? _isolateEntry;

  /// When true, on worker isolate error/done
  /// `WorkerCrashRecovery.handleWorkerCrash` is invoked after failing pending
  /// requests. All previous connection IDs are invalid after recovery; callers
  /// must reconnect.
  final bool autoRecoverOnWorkerCrash;

  SendPort? _workerSendPort;
  ReceivePort? _receivePort;
  Isolate? _workerIsolate;
  bool _isInitialized = false;
  int _requestIdCounter = 0;
  final Map<int, Completer<WorkerResponse>> _pendingRequests = {};
  final Map<int, List<String>> _namedParamOrderByStmtId = {};

  /// Initializes the worker isolate and ODBC environment.
  ///
  /// 1. Spawns a new isolate via [Isolate.spawn].
  /// 2. Loads the ODBC driver in the worker.
  /// 3. Initializes the ODBC environment there.
  /// 4. Returns when the worker is ready to accept requests.
  ///
  /// One-time cost is typically ~50–100 ms. Safe to call multiple times;
  /// later calls return immediately if already initialized.
  ///
  /// Returns `true` if initialization succeeds, `false` otherwise.
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    final handshake = Completer<SendPort>();
    _receivePort = ReceivePort();
    _receivePort!.listen(
      (Object? message) {
        if (message is SendPort) {
          if (!handshake.isCompleted) handshake.complete(message);
        } else if (message is WorkerResponse) {
          _handleResponse(message);
        }
      },
      onError: (Object error, StackTrace stackTrace) async {
        _failAllPending(
          AsyncError(
            code: AsyncErrorCode.workerTerminated,
            message: 'Worker isolate error: $error',
          ),
        );
        if (autoRecoverOnWorkerCrash) {
          AppLogger.severe('Worker isolate crashed: $error', error, stackTrace);
          await recoverWorker();
        }
      },
      onDone: () async {
        if (_pendingRequests.isNotEmpty) {
          _failAllPending(
            const AsyncError(
              code: AsyncErrorCode.workerTerminated,
              message: 'Worker isolate terminated',
            ),
          );
        }
        if (autoRecoverOnWorkerCrash) {
          AppLogger.severe('Worker isolate terminated');
          await recoverWorker();
        }
      },
    );

    _workerIsolate = await Isolate.spawn(
      _isolateEntry ?? workerEntry,
      _receivePort!.sendPort,
    );
    _workerSendPort = await handshake.future;

    final initResp = await _sendRequest<InitializeResponse>(
      InitializeRequest(_nextRequestId()),
    );
    return _isInitialized = initResp.success;
  }

  Future<T> _sendRequest<T extends WorkerResponse>(
    WorkerRequest request,
  ) async {
    if (_workerSendPort == null) {
      throw StateError('Worker not initialized');
    }
    final completer = Completer<WorkerResponse>();
    _pendingRequests[request.requestId] = completer;
    _workerSendPort!.send(request);

    final effectiveTimeout = _requestTimeout ?? _defaultRequestTimeout;
    if (effectiveTimeout == Duration.zero) {
      return await completer.future as T;
    }

    return await completer.future.timeout(
      effectiveTimeout,
      onTimeout: () {
        _pendingRequests.remove(request.requestId);
        throw AsyncError(
          code: AsyncErrorCode.requestTimeout,
          message:
              'Worker did not respond within ${effectiveTimeout.inSeconds}s',
        );
      },
    ) as T;
  }

  void _failAllPending(AsyncError error) {
    final pending = Map<int, Completer<WorkerResponse>>.from(_pendingRequests);
    _pendingRequests.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
  }

  void _handleResponse(WorkerResponse response) {
    final completer = _pendingRequests.remove(response.requestId);
    completer?.complete(response);
  }

  int _nextRequestId() => _requestIdCounter++;

  /// Whether the worker isolate and ODBC environment are initialized.
  bool get isInitialized => _isInitialized;

  /// Worker isolate, exposed for testing (e.g., to simulate crash).
  Isolate? get workerIsolateForTesting => _workerIsolate;

  /// Opens a connection in the worker using [connectionString].
  ///
  /// [timeoutMs] is the login timeout in milliseconds (0 = driver default).
  /// Throws [AsyncError] with [AsyncErrorCode.connectionFailed] if the
  /// connection fails. Call [initialize] before [connect].
  ///
  /// Returns the native connection ID (positive integer) on success.
  Future<int> connect(String connectionString, {int timeoutMs = 0}) async {
    if (!_isInitialized) {
      throw const AsyncError(
        code: AsyncErrorCode.notInitialized,
        message: 'Environment not initialized. Call initialize() first.',
      );
    }
    final r = await _sendRequest<ConnectResponse>(
      ConnectRequest(_nextRequestId(), connectionString, timeoutMs: timeoutMs),
    );
    if (r.error != null) {
      throw AsyncError(
        code: AsyncErrorCode.connectionFailed,
        message: r.error!,
      );
    }
    return r.connectionId;
  }

  /// Closes the connection identified by [connectionId] in the worker.
  ///
  /// Returns `true` if disconnect succeeded, `false` otherwise.
  Future<bool> disconnect(int connectionId) async {
    final r = await _sendRequest<BoolResponse>(
      DisconnectRequest(_nextRequestId(), connectionId),
    );
    return r.value;
  }

  /// Returns the last error message from the worker (plain text).
  Future<String> getError() async {
    final r =
        await _sendRequest<GetErrorResponse>(GetErrorRequest(_nextRequestId()));
    return r.message;
  }

  /// Detects the database driver from a connection string.
  ///
  /// Returns the driver name (e.g. "sqlserver", "oracle", "postgres") if
  /// detected, or null if unknown.
  Future<String?> detectDriver(String connectionString) async {
    final r = await _sendRequest<DetectDriverResponse>(
      DetectDriverRequest(_nextRequestId(), connectionString),
    );
    return r.driverName;
  }

  /// Returns the last structured error (message, SQLSTATE, native code), or
  /// `null` if there is no error.
  Future<StructuredError?> getStructuredError() async {
    final r = await _sendRequest<StructuredErrorResponse>(
      GetStructuredErrorRequest(_nextRequestId()),
    );
    if (r.error != null) return null;
    if (r.message.isEmpty && r.sqlStateString == null) return null;
    final sqlState = (r.sqlStateString ?? '').codeUnits;
    return StructuredError(
      message: r.message,
      sqlState: sqlState.isNotEmpty ? sqlState : List.filled(5, 0),
      nativeCode: r.nativeCode ?? 0,
    );
  }

  /// Starts a transaction in the worker for [connectionId] with
  /// [isolationLevel]. Returns the transaction ID on success.
  Future<int> beginTransaction(int connectionId, int isolationLevel) async {
    final r = await _sendRequest<IntResponse>(
      BeginTransactionRequest(_nextRequestId(), connectionId, isolationLevel),
    );
    return r.value;
  }

  /// Commits the transaction identified by [txnId] in the worker.
  Future<bool> commitTransaction(int txnId) async {
    final r = await _sendRequest<BoolResponse>(
      CommitTransactionRequest(_nextRequestId(), txnId),
    );
    return r.value;
  }

  /// Rolls back the transaction identified by [txnId] in the worker.
  Future<bool> rollbackTransaction(int txnId) async {
    final r = await _sendRequest<BoolResponse>(
      RollbackTransactionRequest(_nextRequestId(), txnId),
    );
    return r.value;
  }

  /// Creates a savepoint [name] within the transaction [txnId] in the worker.
  Future<bool> createSavepoint(int txnId, String name) async {
    final r = await _sendRequest<BoolResponse>(
      SavepointCreateRequest(_nextRequestId(), txnId, name),
    );
    return r.value;
  }

  /// Rolls back to savepoint [name] in transaction [txnId].
  /// Transaction stays active.
  Future<bool> rollbackToSavepoint(int txnId, String name) async {
    final r = await _sendRequest<BoolResponse>(
      SavepointRollbackRequest(_nextRequestId(), txnId, name),
    );
    return r.value;
  }

  /// Releases savepoint [name] in transaction [txnId].
  /// Transaction stays active.
  Future<bool> releaseSavepoint(int txnId, String name) async {
    final r = await _sendRequest<BoolResponse>(
      SavepointReleaseRequest(_nextRequestId(), txnId, name),
    );
    return r.value;
  }

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
  /// to positional placeholders before prepare. On success, internal metadata
  /// is stored so [executePreparedNamed] can bind values by name.
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
  /// missing or required parameters are not provided.
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
  }) async {
    final bytes = params.isEmpty ? Uint8List(0) : serializeParams(params);
    final r = await _sendRequest<QueryResponse>(
      ExecuteQueryParamsRequest(
        _nextRequestId(),
        connectionId,
        sql,
        bytes,
        maxResultBufferBytes: maxBufferBytes,
      ),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Executes [sql] on [connectionId] using named parameters.
  ///
  /// Supports `@name` and `:name` syntax, converting placeholders to
  /// positional order before sending the query to the worker.
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

  /// Creates a connection pool in the worker. Returns pool ID on success.
  Future<int> poolCreate(String connectionString, int maxSize) async {
    final r = await _sendRequest<IntResponse>(
      PoolCreateRequest(_nextRequestId(), connectionString, maxSize),
    );
    return r.value;
  }

  /// Obtains a connection from pool [poolId]. Returns connection ID on success.
  Future<int> poolGetConnection(int poolId) async {
    final r = await _sendRequest<IntResponse>(
      PoolGetConnectionRequest(_nextRequestId(), poolId),
    );
    return r.value;
  }

  /// Returns [connectionId] to its pool.
  Future<bool> poolReleaseConnection(int connectionId) async {
    final r = await _sendRequest<BoolResponse>(
      PoolReleaseConnectionRequest(_nextRequestId(), connectionId),
    );
    return r.value;
  }

  /// Runs a health check on pool [poolId].
  Future<bool> poolHealthCheck(int poolId) async {
    final r = await _sendRequest<BoolResponse>(
      PoolHealthCheckRequest(_nextRequestId(), poolId),
    );
    return r.value;
  }

  /// Returns the current state (size, idle) of pool [poolId],
  /// or `null` on error.
  Future<({int size, int idle})?> poolGetState(int poolId) async {
    final r = await _sendRequest<PoolStateResponse>(
      PoolGetStateRequest(_nextRequestId(), poolId),
    );
    if (r.error != null || r.size == null) return null;
    return (size: r.size!, idle: r.idle ?? 0);
  }

  /// Closes pool [poolId] in the worker.
  Future<bool> poolClose(int poolId) async {
    final r = await _sendRequest<BoolResponse>(
      PoolCloseRequest(_nextRequestId(), poolId),
    );
    return r.value;
  }

  /// Performs bulk insert on [connectionId]: [table], [columns], [dataBuffer],
  /// [rowCount]. Returns rows inserted, or negative on error.
  Future<int> bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) async {
    final r = await _sendRequest<IntResponse>(
      BulkInsertArrayRequest(
        _nextRequestId(),
        connectionId,
        table,
        columns,
        dataBuffer,
        rowCount,
      ),
    );
    return r.value;
  }

  /// Performs parallel bulk insert on [poolId]. Returns rows inserted,
  /// or negative value on error.
  Future<int> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int parallelism,
  ) async {
    final r = await _sendRequest<IntResponse>(
      BulkInsertParallelRequest(
        _nextRequestId(),
        poolId,
        table,
        columns,
        dataBuffer,
        parallelism,
      ),
    );
    return r.value;
  }

  /// Returns ODBC metrics from the worker (query count, errors, latency, etc.).
  Future<OdbcMetrics?> getMetrics() async {
    final r = await _sendRequest<MetricsResponse>(
      GetMetricsRequest(_nextRequestId()),
    );
    if (r.error != null) return null;
    return OdbcMetrics(
      queryCount: r.queryCount,
      errorCount: r.errorCount,
      uptimeSecs: r.uptimeSecs,
      totalLatencyMillis: r.totalLatencyMillis,
      avgLatencyMillis: r.avgLatencyMillis,
    );
  }

  /// Returns prepared statement cache metrics from the worker.
  Future<PreparedStatementMetrics?> getCacheMetrics() async {
    final r = await _sendRequest<CacheMetricsResponse>(
      GetCacheMetricsRequest(_nextRequestId()),
    );
    if (r.error != null) return null;
    return PreparedStatementMetrics(
      cacheSize: r.cacheSize,
      cacheMaxSize: r.cacheMaxSize,
      cacheHits: r.cacheHits,
      cacheMisses: r.cacheMisses,
      totalPrepares: r.totalPrepares,
      totalExecutions: r.totalExecutions,
      memoryUsageBytes: r.memoryUsageBytes,
      avgExecutionsPerStmt: r.avgExecutionsPerStmt,
    );
  }

  /// Clears the prepared statement cache in the worker.
  Future<bool> clearStatementCache() async {
    final r = await _sendRequest<ClearCacheResponse>(
      ClearCacheRequest(_nextRequestId()),
    );
    return r.error == null;
  }

  Future<int> _streamStart(
    int connectionId,
    String sql, {
    int chunkSize = 1000,
  }) async {
    final r = await _sendRequest<IntResponse>(
      StreamStartRequest(
        _nextRequestId(),
        connectionId,
        sql,
        chunkSize: chunkSize,
      ),
    );
    return r.value;
  }

  Future<int> _streamStartBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async {
    final r = await _sendRequest<IntResponse>(
      StreamStartBatchedRequest(
        _nextRequestId(),
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      ),
    );
    return r.value;
  }

  Future<StreamFetchResponse> _streamFetch(int streamId) {
    return _sendRequest<StreamFetchResponse>(
      StreamFetchRequest(_nextRequestId(), streamId),
    );
  }

  Future<bool> _streamClose(int streamId) async {
    final r = await _sendRequest<BoolResponse>(
      StreamCloseRequest(_nextRequestId(), streamId),
    );
    return r.value;
  }

  /// Runs [sql] in the worker using native batched streaming.
  ///
  /// This path uses `odbc_stream_start_batched` + `odbc_stream_fetch`,
  /// yielding chunks progressively. [maxBufferBytes] caps internal pending
  /// bytes for message framing.
  Stream<ParsedRowBuffer> streamQueryBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int? maxBufferBytes,
  }) async* {
    final streamId = await _streamStartBatched(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    );
    if (streamId == 0) {
      return;
    }

    var pending = BytesBuilder(copy: false);
    final limit = maxBufferBytes;
    try {
      while (true) {
        final fetched = await _streamFetch(streamId);
        if (!fetched.success) {
          return;
        }

        final data = fetched.data;
        if (data != null && data.isNotEmpty) {
          pending.add(data);
          if (limit != null && pending.length > limit) {
            throw const AsyncError(
              code: AsyncErrorCode.queryFailed,
              message: 'Streaming buffer exceeded maxBufferBytes',
            );
          }

          while (pending.length >= BinaryProtocolParser.headerSize) {
            final all = pending.toBytes();
            final msgLen = BinaryProtocolParser.messageLengthFromHeader(all);
            if (all.length < msgLen) {
              break;
            }

            final msg = all.sublist(0, msgLen);
            yield BinaryProtocolParser.parse(msg);

            final remainder = all.sublist(msgLen);
            pending = BytesBuilder(copy: false);
            if (remainder.isNotEmpty) {
              pending.add(remainder);
            }
          }
        }

        if (!fetched.hasMore) {
          break;
        }
      }

      if (pending.length > 0) {
        throw const FormatException(
          'Leftover bytes after stream; expected complete protocol messages',
        );
      }
    } finally {
      await _streamClose(streamId);
    }
  }

  /// Runs [sql] in the worker using native streaming.
  ///
  /// This path uses `odbc_stream_start` + `odbc_stream_fetch`. Data is
  /// accumulated and parsed at the end, matching sync `streamQuery` behavior.
  /// [maxBufferBytes] caps total accumulated bytes.
  Stream<ParsedRowBuffer> streamQuery(
    int connectionId,
    String sql, {
    int chunkSize = 1000,
    int? maxBufferBytes,
  }) async* {
    final streamId = await _streamStart(
      connectionId,
      sql,
      chunkSize: chunkSize,
    );
    if (streamId == 0) {
      return;
    }

    final buffer = BytesBuilder(copy: false);
    final limit = maxBufferBytes;
    try {
      while (true) {
        final fetched = await _streamFetch(streamId);
        if (!fetched.success) {
          return;
        }

        final data = fetched.data;
        if (data != null && data.isNotEmpty) {
          buffer.add(data);
          if (limit != null && buffer.length > limit) {
            throw const AsyncError(
              code: AsyncErrorCode.queryFailed,
              message: 'Streaming buffer exceeded maxBufferBytes',
            );
          }
        }

        if (!fetched.hasMore) {
          break;
        }
      }

      if (buffer.length > 0) {
        yield BinaryProtocolParser.parse(buffer.toBytes());
      }
    } finally {
      await _streamClose(streamId);
    }
  }

  /// Disposes the current worker and re-initializes a fresh one.
  ///
  /// All previous connection IDs are invalid after this. Callers must
  /// reconnect. Use when [autoRecoverOnWorkerCrash] is true and the worker
  /// has crashed.
  Future<void> recoverWorker() async {
    dispose();
    await initialize();
  }

  /// Shuts down the worker isolate and releases resources.
  ///
  /// Completes any pending requests with error before shutting down. Sends
  /// shutdown to the worker, kills the isolate, and closes the receive port.
  /// Call when the async connection is no longer needed. After [dispose],
  /// [isInitialized] is false and [initialize] can be called again. In-flight
  /// requests will complete with [AsyncError] (workerTerminated).
  void dispose() {
    _failAllPending(
      const AsyncError(
        code: AsyncErrorCode.workerTerminated,
        message: 'Connection disposed; worker shutting down',
      ),
    );
    _isInitialized = false;
    _workerSendPort?.send('shutdown');
    _workerIsolate?.kill();
    _receivePort?.close();
    _namedParamOrderByStmtId.clear();
    _workerSendPort = null;
    _workerIsolate = null;
    _receivePort = null;
  }
}

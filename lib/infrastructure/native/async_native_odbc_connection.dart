import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/isolate/worker_isolate.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
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
/// ## Example
///
/// ```dart
/// final async = AsyncNativeOdbcConnection();
/// await async.initialize();
///
/// final connId = await async.connect(dsn);
/// final data = await async.executeQueryParams(connId, 'SELECT 1', []);
/// await async.disconnect(connId);
///
/// async.dispose();
/// ```
///
/// See also:
/// - `worker_isolate.dart` for the worker entry and request handling.
/// - [WorkerRequest] and [WorkerResponse] for the message protocol.
class AsyncNativeOdbcConnection {
  AsyncNativeOdbcConnection();

  SendPort? _workerSendPort;
  ReceivePort? _receivePort;
  Isolate? _workerIsolate;
  bool _isInitialized = false;
  int _requestIdCounter = 0;
  final Map<int, Completer<WorkerResponse>> _pendingRequests = {};

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
    _receivePort!.listen((Object? message) {
      if (message is SendPort) {
        if (!handshake.isCompleted) handshake.complete(message);
      } else if (message is WorkerResponse) {
        _handleResponse(message);
      }
    });

    _workerIsolate = await Isolate.spawn(
      workerEntry,
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
    return await completer.future as T;
  }

  void _handleResponse(WorkerResponse response) {
    final completer = _pendingRequests.remove(response.requestId);
    completer?.complete(response);
  }

  int _nextRequestId() => _requestIdCounter++;

  /// Whether the worker isolate and ODBC environment are initialized.
  bool get isInitialized => _isInitialized;

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

  /// Executes a prepared statement [stmtId] in the worker with optional
  /// [params]. Returns the binary result, or `null` on error.
  Future<Uint8List?> executePrepared(
    int stmtId,
    List<ParamValue>? params,
  ) async {
    final bytes =
        params == null || params.isEmpty ? null : serializeParams(params);
    final r = await _sendRequest<QueryResponse>(
      ExecutePreparedRequest(
        _nextRequestId(),
        stmtId,
        bytes ?? Uint8List(0),
      ),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Executes [sql] on [connectionId] with [params] in the worker.
  ///
  /// Returns the binary result (same format as sync API), or `null` on error.
  Future<Uint8List?> executeQueryParams(
    int connectionId,
    String sql,
    List<ParamValue> params,
  ) async {
    final bytes = params.isEmpty ? Uint8List(0) : serializeParams(params);
    final r = await _sendRequest<QueryResponse>(
      ExecuteQueryParamsRequest(
        _nextRequestId(),
        connectionId,
        sql,
        bytes,
      ),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Executes [sql] on [connectionId] for multi-result sets in the worker.
  /// Returns the binary result, or `null` on error.
  Future<Uint8List?> executeQueryMulti(int connectionId, String sql) async {
    final r = await _sendRequest<QueryResponse>(
      ExecuteQueryMultiRequest(_nextRequestId(), connectionId, sql),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Closes the prepared statement [stmtId] in the worker.
  Future<bool> closeStatement(int stmtId) async {
    final r = await _sendRequest<BoolResponse>(
      CloseStatementRequest(_nextRequestId(), stmtId),
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

  /// Runs [sql] in the worker and yields one [ParsedRowBuffer].
  ///
  /// Fetches the full result in one shot, then parses it. For very large
  /// result sets, consider sync mode or a dedicated streaming API.
  /// [fetchSize] and [chunkSize] are hints; behavior may match sync batching.
  Stream<ParsedRowBuffer> streamQueryBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async* {
    final data = await executeQueryParams(connectionId, sql, []);
    if (data == null || data.isEmpty) return;
    yield BinaryProtocolParser.parse(data);
  }

  /// Runs [sql] in the worker and yields one [ParsedRowBuffer].
  ///
  /// Same as [streamQueryBatched] with default chunking; full result is
  /// fetched then parsed. [chunkSize] is a hint.
  Stream<ParsedRowBuffer> streamQuery(
    int connectionId,
    String sql, {
    int chunkSize = 1000,
  }) async* {
    final data = await executeQueryParams(connectionId, sql, []);
    if (data == null || data.isEmpty) return;
    yield BinaryProtocolParser.parse(data);
  }

  /// Shuts down the worker isolate and releases resources.
  ///
  /// Sends shutdown to the worker, kills the isolate, and closes the receive
  /// port. Call when the async connection is no longer needed. After [dispose],
  /// [isInitialized] is false and [initialize] can be called again.
  void dispose() {
    _workerSendPort?.send('shutdown');
    _workerIsolate?.kill();
    _receivePort?.close();
    _workerSendPort = null;
    _workerIsolate = null;
    _receivePort = null;
    _isInitialized = false;
  }
}

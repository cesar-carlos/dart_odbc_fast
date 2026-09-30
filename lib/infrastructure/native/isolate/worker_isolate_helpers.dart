part of 'worker_isolate.dart';

mixin _WorkerIsolateHelpers on _WorkerIsolateState {
  @override
  QueryResponse queryDataResponse(int requestId, Uint8List data) =>
      isolateQueryDataResponse(requestId, data);

  @override
  StreamFetchResponse streamDataResponse({
    required int requestId,
    required bool success,
    required Uint8List? data,
    required bool hasMore,
    String? error,
  }) =>
      isolateStreamDataResponse(
        requestId: requestId,
        success: success,
        data: data,
        hasMore: hasMore,
        error: error,
      );

  void dispatchHelpers(
    WorkerRequest request,
    SendPort sendPort,
    NativeOdbcConnection conn,
  ) {
    switch (request) {
      case InitializeRequest():
        final ok = conn.initialize();
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          InitializeResponse(request.requestId, success: ok),
        );

      case SetLogLevelRequest():
        conn.setLogLevel(request.level);
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          BoolResponse(request.requestId, value: true),
        );

      case ValidateConnectionStringRequest():
        final validationError = conn.validateConnectionString(
          request.connectionString,
        );
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          ValidateConnectionStringResponse(
            request.requestId,
            isValid: validationError == null,
            errorMessage: validationError,
          ),
        );

      case GetDriverCapabilitiesRequest():
        final payload =
            conn.getDriverCapabilitiesJson(request.connectionString);
        if (payload != null) {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            AuditPayloadResponse(request.requestId, payload: payload),
          );
        } else {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            AuditPayloadResponse(
              request.requestId,
              error: _workerError(conn),
            ),
          );
        }

      case GetConnectionDbmsInfoRequest():
        final payload = conn.getConnectionDbmsInfoJson(request.connectionId);
        if (payload != null) {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            AuditPayloadResponse(request.requestId, payload: payload),
          );
        } else {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            AuditPayloadResponse(
              request.requestId,
              error: _workerError(conn),
            ),
          );
        }

      case ConnectRequest():
        try {
          final connId = request.timeoutMs > 0
              ? conn.connectWithTimeout(
                  request.connectionString,
                  request.timeoutMs,
                )
              : conn.connect(request.connectionString);
          if (connId == 0) {
            final err = _workerError(conn);
            _sendWorkerResponse(
              request,
              sendPort,
              conn,
              ConnectResponse(
                request.requestId,
                0,
                error: err.isNotEmpty ? err : 'Connect failed',
              ),
            );
          } else {
            _sendWorkerResponse(
              request,
              sendPort,
              conn,
              ConnectResponse(request.requestId, connId),
            );
          }
        } on Object catch (e, stack) {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            ConnectResponse(
              request.requestId,
              0,
              error: e.toString(),
            ),
            cause: e,
            stackTrace: stack,
          );
        }

      case DisconnectRequest():
        final ok = conn.disconnect(request.connectionId);
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          BoolResponse(request.requestId, value: ok),
        );

      case GetVersionRequest():
        final v = conn.getVersion();
        if (v != null) {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            VersionResponse(
              request.requestId,
              api: v['api'] ?? '',
              abi: v['abi'] ?? '',
            ),
          );
        } else {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            VersionResponse(request.requestId),
          );
        }

      case GetMetricsRequest():
        final m = conn.getMetrics();
        if (m != null) {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            MetricsResponse(
              request.requestId,
              queryCount: m.queryCount,
              errorCount: m.errorCount,
              uptimeSecs: m.uptimeSecs,
              totalLatencyMillis: m.totalLatencyMillis,
              avgLatencyMillis: m.avgLatencyMillis,
            ),
          );
        } else {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            MetricsResponse(
              request.requestId,
              error: _workerError(conn),
            ),
          );
        }
      case GetCacheMetricsRequest():
        final m = conn.getCacheMetrics();
        if (m != null) {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            CacheMetricsResponse(
              request.requestId,
              cacheSize: m.cacheSize,
              cacheMaxSize: m.cacheMaxSize,
              cacheHits: m.cacheHits,
              cacheMisses: m.cacheMisses,
              totalPrepares: m.totalPrepares,
              totalExecutions: m.totalExecutions,
              memoryUsageBytes: m.memoryUsageBytes,
              avgExecutionsPerStmt: m.avgExecutionsPerStmt,
            ),
          );
        } else {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            CacheMetricsResponse(
              request.requestId,
              error: _workerError(conn),
            ),
          );
        }

      case ClearCacheRequest():
        final cleared = conn.clearStatementCache();
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          ClearCacheResponse(
            request.requestId,
            error: cleared ? null : _workerError(conn),
          ),
        );

      case MetadataCacheEnableRequest():
        final ok = conn.metadataCacheEnable(
          maxEntries: request.maxEntries,
          ttlSeconds: request.ttlSeconds,
        );
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          BoolResponse(request.requestId, value: ok),
        );

      case MetadataCacheStatsRequest():
        final payload = conn.getMetadataCacheStatsJson();
        if (payload != null) {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            AuditPayloadResponse(request.requestId, payload: payload),
          );
        } else {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            AuditPayloadResponse(
              request.requestId,
              error: _workerError(conn),
            ),
          );
        }

      case MetadataCacheClearRequest():
        final ok = conn.clearMetadataCache();
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          BoolResponse(request.requestId, value: ok),
        );

      case GetErrorRequest():
        final msg = _workerError(conn);
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          GetErrorResponse(request.requestId, msg),
        );

      case DetectDriverRequest():
        final driverName = conn.detectDriver(request.connectionString);
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          DetectDriverResponse(request.requestId, driverName),
        );

      case GetStructuredErrorRequest():
        final se = conn.getStructuredError();
        if (se != null) {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            StructuredErrorResponse(
              request.requestId,
              message: se.message,
              sqlStateString: se.sqlStateString,
              nativeCode: se.nativeCode,
            ),
          );
        } else {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            StructuredErrorResponse(request.requestId),
          );
        }

      case GetStructuredErrorForConnectionRequest():
        final se = conn.getStructuredErrorForConnection(request.connectionId);
        if (se != null) {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            StructuredErrorResponse(
              request.requestId,
              message: se.message,
              sqlStateString: se.sqlStateString,
              nativeCode: se.nativeCode,
            ),
          );
        } else {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            StructuredErrorResponse(request.requestId),
          );
        }

      case AuditEnableRequest():
        final ok = conn.setAuditEnabled(enabled: request.enabled);
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          BoolResponse(request.requestId, value: ok),
        );

      case AuditGetEventsRequest():
        final payload = conn.getAuditEventsJson(limit: request.limit);
        if (payload != null) {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            AuditPayloadResponse(request.requestId, payload: payload),
          );
        } else {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            AuditPayloadResponse(
              request.requestId,
              error: _workerError(conn),
            ),
          );
        }

      case AuditGetStatusRequest():
        final payload = conn.getAuditStatusJson();
        if (payload != null) {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            AuditPayloadResponse(request.requestId, payload: payload),
          );
        } else {
          _sendWorkerResponse(
            request,
            sendPort,
            conn,
            AuditPayloadResponse(
              request.requestId,
              error: _workerError(conn),
            ),
          );
        }

      case AuditClearRequest():
        final ok = conn.clearAuditEvents();
        _sendWorkerResponse(
          request,
          sendPort,
          conn,
          BoolResponse(request.requestId, value: ok),
        );

      default:
        throw StateError('Unexpected helpers request: ${request.type}');
    }
  }
}

/// Response sent when a worker [WorkerRequest] fails with an exception.
///
/// Isolated for unit tests — production path uses [sendWorkerErrorResponse].
@visibleForTesting
WorkerResponse buildWorkerErrorResponse(WorkerRequest request, String error) {
  final id = request.requestId;
  switch (request) {
    case InitializeRequest():
      return InitializeResponse(id, success: false);
    case ValidateConnectionStringRequest():
      return ValidateConnectionStringResponse(
        id,
        isValid: false,
        errorMessage: error,
      );
    case ConnectRequest():
      return ConnectResponse(id, 0, error: error);
    case DisconnectRequest():
    case CancelStatementRequest():
    case CloseStatementRequest():
    case PoolReleaseConnectionRequest():
    case PoolHealthCheckRequest():
    case PoolSetSizeRequest():
    case PoolCloseRequest():
    case SetLogLevelRequest():
    case CommitTransactionRequest():
    case RollbackTransactionRequest():
    case SavepointCreateRequest():
    case SavepointRollbackRequest():
    case SavepointReleaseRequest():
    case AuditEnableRequest():
    case AuditClearRequest():
    case AsyncCancelRequest():
    case AsyncFreeRequest():
    case StreamCancelRequest():
    case MetadataCacheEnableRequest():
    case MetadataCacheClearRequest():
      return BoolResponse(id, value: false);
    case ExecuteQueryParamsRequest():
    case ExecuteQueryMultiRequest():
    case ExecuteQueryMultiParamsRequest():
    case ExecutePreparedRequest():
    case CatalogTablesRequest():
    case CatalogColumnsRequest():
    case CatalogTypeInfoRequest():
    case CatalogPrimaryKeysRequest():
    case CatalogForeignKeysRequest():
    case CatalogIndexesRequest():
    case AsyncGetResultRequest():
      return QueryResponse(id, error: error);
    case BeginTransactionRequest():
    case PrepareRequest():
    case PoolCreateRequest():
    case PoolGetConnectionRequest():
    case StreamStartRequest():
    case StreamStartBatchedRequest():
    case StreamStartAsyncRequest():
    case StreamMultiStartBatchedRequest():
    case StreamMultiStartAsyncRequest():
    case ClearAllStatementsRequest():
    case ExecuteAsyncStartRequest():
    case ExecuteAsyncStartParamsRequest():
    case XaStartRequest():
    case XaResumePreparedRequest():
      return IntResponse(id, 0);
    case AsyncPollRequest():
    case StreamPollAsyncRequest():
    case XaIdRequest():
      return IntResponse(id, -1);
    case XaRecoverRequest():
      return XaRecoverResponse(id, error: error);
    case StreamPollFetchRequest():
      return StreamPollFetchResponse(
        id,
        status: -1,
        success: false,
        error: error,
      );
    case StreamFetchRequest():
      return StreamFetchResponse(
        id,
        success: false,
        error: error,
      );
    case StreamCloseRequest():
      return BoolResponse(id, value: false);
    case BulkInsertArrayRequest():
    case BulkInsertParallelRequest():
      return IntResponse(id, -1);
    case PoolGetStateRequest():
      return PoolStateResponse(id, error: error);
    case GetDriverCapabilitiesRequest():
    case GetConnectionDbmsInfoRequest():
    case PoolGetStateJsonRequest():
      return AuditPayloadResponse(id, error: error);
    case GetVersionRequest():
      return VersionResponse(id);
    case GetMetricsRequest():
      return MetricsResponse(id, error: error);
    case GetErrorRequest():
      return GetErrorResponse(id, error);
    case GetStructuredErrorRequest():
    case GetStructuredErrorForConnectionRequest():
      return StructuredErrorResponse(id, message: error, error: error);
    case DetectDriverRequest():
      return DetectDriverResponse(id, null);
    case AuditGetEventsRequest():
    case AuditGetStatusRequest():
    case MetadataCacheStatsRequest():
      return AuditPayloadResponse(id, error: error);
    case GetCacheMetricsRequest():
      return CacheMetricsResponse(id, error: error);
    case ClearCacheRequest():
      return ClearCacheResponse(id, error: error);
  }
}

void sendWorkerErrorResponse(
  WorkerRequest request,
  SendPort sendPort,
  String error,
) {
  sendPort.send(buildWorkerErrorResponse(request, error));
}

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';

/// Entry point for the worker isolate. Must be top-level or static.
///
/// [mainSendPort] is the SendPort of the main isolate's ReceivePort.
/// The worker sends its own SendPort as the first message, then listens
/// for [WorkerRequest] messages and responds with [WorkerResponse].
void workerEntry(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  late NativeOdbcConnection conn;
  try {
    conn = NativeOdbcConnection();
  } on Object catch (_) {
    mainSendPort.send(const InitializeResponse(0, success: false));
    return;
  }

  receivePort.listen((message) {
    if (message == 'shutdown') {
      conn.dispose();
      receivePort.close();
      return;
    }
    if (message is WorkerRequest) {
      _handleRequest(message, mainSendPort, conn);
    }
  });
}

void _handleRequest(
  WorkerRequest request,
  SendPort sendPort,
  NativeOdbcConnection conn,
) {
  try {
    switch (request) {
      case InitializeRequest():
        final ok = conn.initialize();
        sendPort.send(InitializeResponse(request.requestId, success: ok));

      case ValidateConnectionStringRequest():
        final validationError = conn.validateConnectionString(
          request.connectionString,
        );
        sendPort.send(
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
          sendPort.send(
            AuditPayloadResponse(request.requestId, payload: payload),
          );
        } else {
          sendPort.send(
            AuditPayloadResponse(
              request.requestId,
              error: conn.getError(),
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
            final err = conn.getError();
            sendPort.send(
              ConnectResponse(
                request.requestId,
                0,
                error: err.isNotEmpty ? err : 'Connect failed',
              ),
            );
          } else {
            sendPort.send(ConnectResponse(request.requestId, connId));
          }
        } on Object catch (e) {
          sendPort.send(
            ConnectResponse(
              request.requestId,
              0,
              error: e.toString(),
            ),
          );
        }

      case DisconnectRequest():
        final ok = conn.disconnect(request.connectionId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case ExecuteQueryParamsRequest():
        final data = conn.executeQueryParamsRaw(
          request.connectionId,
          request.sql,
          request.serializedParams.isEmpty ? null : request.serializedParams,
          maxBufferBytes: request.maxResultBufferBytes,
        );
        if (data != null) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          final err = conn.getError();
          final message = err.isNotEmpty && err != 'No error'
              ? err
              : 'Query failed (native returned no data; check connection/driver state)';
          sendPort.send(QueryResponse(request.requestId, error: message));
        }

      case ExecuteQueryMultiRequest():
        final data = conn.executeQueryMulti(
          request.connectionId,
          request.sql,
          maxBufferBytes: request.maxResultBufferBytes,
        );
        if (data != null) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          final err = conn.getError();
          final message = err.isNotEmpty && err != 'No error'
              ? err
              : 'Multi-result query failed (native returned no data; check connection/driver state)';
          sendPort.send(QueryResponse(request.requestId, error: message));
        }

      case ExecuteQueryMultiParamsRequest():
        final bytes =
            request.serializedParams.isEmpty ? null : request.serializedParams;
        final data = conn.executeQueryMultiParams(
          request.connectionId,
          request.sql,
          bytes,
          maxBufferBytes: request.maxResultBufferBytes,
        );
        if (data != null) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          final err = conn.getError();
          final message = err.isNotEmpty && err != 'No error'
              ? err
              : 'Multi-result query (with params) failed '
                  '(native returned no data)';
          sendPort.send(QueryResponse(request.requestId, error: message));
        }

      case BeginTransactionRequest():
        final txnId = conn.beginTransaction(
          request.connectionId,
          request.isolationLevel,
          savepointDialect: request.savepointDialect,
          accessMode: request.accessMode,
        );
        sendPort.send(IntResponse(request.requestId, txnId));

      case CommitTransactionRequest():
        final ok = conn.commitTransaction(request.txnId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case RollbackTransactionRequest():
        final ok = conn.rollbackTransaction(request.txnId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case SavepointCreateRequest():
        final ok = conn.createSavepoint(request.txnId, request.name);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case SavepointRollbackRequest():
        final ok = conn.rollbackToSavepoint(request.txnId, request.name);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case SavepointReleaseRequest():
        final ok = conn.releaseSavepoint(request.txnId, request.name);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case PrepareRequest():
        final stmtId = conn.prepare(
          request.connectionId,
          request.sql,
          timeoutMs: request.timeoutMs,
        );
        sendPort.send(IntResponse(request.requestId, stmtId));

      case ExecutePreparedRequest():
        final bytes =
            request.serializedParams.isEmpty ? null : request.serializedParams;
        final data = conn.executePreparedRaw(
          request.stmtId,
          bytes,
          request.timeoutOverrideMs,
          request.fetchSize,
          maxBufferBytes: request.maxResultBufferBytes,
        );
        if (data != null) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          final err = conn.getError();
          final message = err.isNotEmpty && err != 'No error'
              ? err
              : 'Execute prepared failed (native returned no data; check connection/driver state)';
          sendPort.send(QueryResponse(request.requestId, error: message));
        }

      case CancelStatementRequest():
        final ok = conn.cancelStatement(request.stmtId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case CloseStatementRequest():
        final ok = conn.closeStatement(request.stmtId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case ClearAllStatementsRequest():
        final code = conn.clearAllStatements();
        sendPort.send(IntResponse(request.requestId, code));

      case StreamStartRequest():
        final streamId = conn.streamStart(
          request.connectionId,
          request.sql,
          chunkSize: request.chunkSize,
        );
        sendPort.send(IntResponse(request.requestId, streamId));

      case StreamStartBatchedRequest():
        final streamId = conn.streamStartBatched(
          request.connectionId,
          request.sql,
          fetchSize: request.fetchSize,
          chunkSize: request.chunkSize,
        );
        sendPort.send(IntResponse(request.requestId, streamId));

      case StreamStartAsyncRequest():
        final streamId = conn.streamStartAsync(
          request.connectionId,
          request.sql,
          fetchSize: request.fetchSize,
          chunkSize: request.chunkSize,
        );
        sendPort.send(IntResponse(request.requestId, streamId ?? 0));

      case StreamMultiStartBatchedRequest():
        final streamId = conn.streamMultiStartBatched(
          request.connectionId,
          request.sql,
          chunkSize: request.chunkSize,
        );
        sendPort.send(IntResponse(request.requestId, streamId ?? 0));

      case StreamMultiStartAsyncRequest():
        final streamId = conn.streamMultiStartAsync(
          request.connectionId,
          request.sql,
          chunkSize: request.chunkSize,
        );
        sendPort.send(IntResponse(request.requestId, streamId ?? 0));

      case StreamPollAsyncRequest():
        final status = conn.streamPollAsync(request.streamId);
        sendPort.send(IntResponse(request.requestId, status ?? -1));

      case StreamFetchRequest():
        final result = conn.streamFetch(request.streamId);
        sendPort.send(
          StreamFetchResponse(
            request.requestId,
            success: result.success,
            data: result.data == null ? null : Uint8List.fromList(result.data!),
            hasMore: result.hasMore,
            error: result.success ? null : conn.getError(),
          ),
        );

      case StreamCancelRequest():
        final ok = conn.streamCancel(request.streamId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case StreamCloseRequest():
        final ok = conn.streamClose(request.streamId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case PoolCreateRequest():
        final poolId = conn.poolCreate(
          request.connectionString,
          request.maxSize,
        );
        sendPort.send(IntResponse(request.requestId, poolId));

      case PoolGetConnectionRequest():
        final connId = conn.poolGetConnection(request.poolId);
        sendPort.send(IntResponse(request.requestId, connId));

      case PoolReleaseConnectionRequest():
        final ok = conn.poolReleaseConnection(request.connectionId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case PoolHealthCheckRequest():
        final ok = conn.poolHealthCheck(request.poolId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case PoolGetStateRequest():
        final state = conn.poolGetState(request.poolId);
        if (state != null) {
          sendPort.send(
            PoolStateResponse(
              request.requestId,
              size: state.size,
              idle: state.idle,
            ),
          );
        } else {
          sendPort.send(
            PoolStateResponse(
              request.requestId,
              error: conn.getError(),
            ),
          );
        }

      case PoolGetStateJsonRequest():
        final payload = conn.poolGetStateJson(request.poolId);
        if (payload != null) {
          sendPort.send(
            AuditPayloadResponse(
              request.requestId,
              payload: jsonEncode(payload),
            ),
          );
        } else {
          sendPort.send(
            AuditPayloadResponse(
              request.requestId,
              error: conn.getError(),
            ),
          );
        }

      case PoolSetSizeRequest():
        final ok = conn.poolSetSize(request.poolId, request.newMaxSize);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case PoolCloseRequest():
        final ok = conn.poolClose(request.poolId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case BulkInsertArrayRequest():
        final rows = conn.bulkInsertArray(
          request.connectionId,
          request.table,
          request.columns,
          request.dataBuffer,
          request.rowCount,
        );
        sendPort.send(IntResponse(request.requestId, rows));

      case BulkInsertParallelRequest():
        final rows = conn.bulkInsertParallel(
          request.poolId,
          request.table,
          request.columns,
          request.dataBuffer,
          request.parallelism,
        );
        sendPort.send(IntResponse(request.requestId, rows));

      case GetVersionRequest():
        final v = conn.getVersion();
        if (v != null) {
          sendPort.send(
            VersionResponse(
              request.requestId,
              api: v['api'] ?? '',
              abi: v['abi'] ?? '',
            ),
          );
        } else {
          sendPort.send(VersionResponse(request.requestId));
        }

      case GetMetricsRequest():
        final m = conn.getMetrics();
        if (m != null) {
          sendPort.send(
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
          sendPort.send(
            MetricsResponse(
              request.requestId,
              error: conn.getError(),
            ),
          );
        }
      case GetCacheMetricsRequest():
        final m = conn.getCacheMetrics();
        if (m != null) {
          sendPort.send(
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
          sendPort.send(
            CacheMetricsResponse(
              request.requestId,
              error: conn.getError(),
            ),
          );
        }

      case ClearCacheRequest():
        final cleared = conn.clearStatementCache();
        sendPort.send(
          ClearCacheResponse(
            request.requestId,
            error: cleared ? null : conn.getError(),
          ),
        );

      case MetadataCacheEnableRequest():
        final ok = conn.metadataCacheEnable(
          maxEntries: request.maxEntries,
          ttlSeconds: request.ttlSeconds,
        );
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case MetadataCacheStatsRequest():
        final payload = conn.getMetadataCacheStatsJson();
        if (payload != null) {
          sendPort.send(
            AuditPayloadResponse(request.requestId, payload: payload),
          );
        } else {
          sendPort.send(
            AuditPayloadResponse(
              request.requestId,
              error: conn.getError(),
            ),
          );
        }

      case MetadataCacheClearRequest():
        final ok = conn.clearMetadataCache();
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case CatalogTablesRequest():
        final data = conn.catalogTables(
          request.connectionId,
          catalog: request.catalog,
          schema: request.schema,
        );
        if (data != null) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          final err = conn.getError();
          final message = err.isNotEmpty && err != 'No error'
              ? err
              : 'Catalog tables failed (native returned no data; check connection/driver state)';
          sendPort.send(QueryResponse(request.requestId, error: message));
        }

      case CatalogColumnsRequest():
        final data = conn.catalogColumns(
          request.connectionId,
          request.table,
        );
        if (data != null) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          final err = conn.getError();
          final message = err.isNotEmpty && err != 'No error'
              ? err
              : 'Catalog columns failed (native returned no data; check connection/driver state)';
          sendPort.send(QueryResponse(request.requestId, error: message));
        }

      case CatalogTypeInfoRequest():
        final data = conn.catalogTypeInfo(request.connectionId);
        if (data != null) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          final err = conn.getError();
          final message = err.isNotEmpty && err != 'No error'
              ? err
              : 'Catalog type info failed (native returned no data; check connection/driver state)';
          sendPort.send(QueryResponse(request.requestId, error: message));
        }

      case CatalogPrimaryKeysRequest():
        final data = conn.catalogPrimaryKeys(
          request.connectionId,
          request.table,
        );
        if (data != null) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          final err = conn.getError();
          final message = err.isNotEmpty && err != 'No error'
              ? err
              : 'Catalog primary keys failed (native returned no data; check connection/driver state)';
          sendPort.send(QueryResponse(request.requestId, error: message));
        }

      case CatalogForeignKeysRequest():
        final data = conn.catalogForeignKeys(
          request.connectionId,
          request.table,
        );
        if (data != null) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          final err = conn.getError();
          final message = err.isNotEmpty && err != 'No error'
              ? err
              : 'Catalog foreign keys failed (native returned no data; check connection/driver state)';
          sendPort.send(QueryResponse(request.requestId, error: message));
        }

      case CatalogIndexesRequest():
        final data = conn.catalogIndexes(
          request.connectionId,
          request.table,
        );
        if (data != null) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          final err = conn.getError();
          final message = err.isNotEmpty && err != 'No error'
              ? err
              : 'Catalog indexes failed (native returned no data; check connection/driver state)';
          sendPort.send(QueryResponse(request.requestId, error: message));
        }

      case GetErrorRequest():
        final msg = conn.getError();
        sendPort.send(GetErrorResponse(request.requestId, msg));

      case DetectDriverRequest():
        final driverName = conn.detectDriver(request.connectionString);
        sendPort.send(DetectDriverResponse(request.requestId, driverName));

      case GetStructuredErrorRequest():
        final se = conn.getStructuredError();
        if (se != null) {
          sendPort.send(
            StructuredErrorResponse(
              request.requestId,
              message: se.message,
              sqlStateString: se.sqlStateString,
              nativeCode: se.nativeCode,
            ),
          );
        } else {
          sendPort.send(StructuredErrorResponse(request.requestId));
        }

      case AuditEnableRequest():
        final ok = conn.setAuditEnabled(enabled: request.enabled);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case AuditGetEventsRequest():
        final payload = conn.getAuditEventsJson(limit: request.limit);
        if (payload != null) {
          sendPort.send(
            AuditPayloadResponse(request.requestId, payload: payload),
          );
        } else {
          sendPort.send(
            AuditPayloadResponse(
              request.requestId,
              error: conn.getError(),
            ),
          );
        }

      case AuditGetStatusRequest():
        final payload = conn.getAuditStatusJson();
        if (payload != null) {
          sendPort.send(
            AuditPayloadResponse(request.requestId, payload: payload),
          );
        } else {
          sendPort.send(
            AuditPayloadResponse(
              request.requestId,
              error: conn.getError(),
            ),
          );
        }

      case AuditClearRequest():
        final ok = conn.clearAuditEvents();
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case ExecuteAsyncStartRequest():
        final asyncRequestId = conn.executeAsyncStart(
          request.connectionId,
          request.sql,
        );
        sendPort.send(IntResponse(request.requestId, asyncRequestId ?? 0));

      case AsyncPollRequest():
        final status = conn.asyncPoll(request.asyncRequestId);
        sendPort.send(IntResponse(request.requestId, status ?? -1));

      case AsyncGetResultRequest():
        final data = conn.asyncGetResult(request.asyncRequestId);
        if (data != null) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          sendPort.send(
            QueryResponse(request.requestId, error: conn.getError()),
          );
        }

      case AsyncCancelRequest():
        final ok = conn.asyncCancel(request.asyncRequestId);
        sendPort.send(BoolResponse(request.requestId, value: ok));

      case AsyncFreeRequest():
        final ok = conn.asyncFree(request.asyncRequestId);
        sendPort.send(BoolResponse(request.requestId, value: ok));
    }
  } on Object catch (e, st) {
    _sendErrorResponse(request, sendPort, '$e\n$st');
  }
}

void _sendErrorResponse(
  WorkerRequest request,
  SendPort sendPort,
  String error,
) {
  final id = request.requestId;
  switch (request) {
    case InitializeRequest():
      sendPort.send(InitializeResponse(id, success: false));
    case ValidateConnectionStringRequest():
      sendPort.send(
        ValidateConnectionStringResponse(
          id,
          isValid: false,
          errorMessage: error,
        ),
      );
    case ConnectRequest():
      sendPort.send(ConnectResponse(id, 0, error: error));
    case DisconnectRequest():
    case CancelStatementRequest():
    case CloseStatementRequest():
    case PoolReleaseConnectionRequest():
    case PoolHealthCheckRequest():
    case PoolSetSizeRequest():
    case PoolCloseRequest():
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
      sendPort.send(BoolResponse(id, value: false));
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
      sendPort.send(QueryResponse(id, error: error));
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
    case AsyncPollRequest():
    case StreamPollAsyncRequest():
      sendPort.send(IntResponse(id, 0));
    case StreamFetchRequest():
      sendPort.send(
        StreamFetchResponse(
          id,
          success: false,
          error: error,
        ),
      );
    case StreamCloseRequest():
      sendPort.send(BoolResponse(id, value: false));
    case BulkInsertArrayRequest():
    case BulkInsertParallelRequest():
      sendPort.send(IntResponse(id, -1));
    case PoolGetStateRequest():
      sendPort.send(PoolStateResponse(id, error: error));
    case GetDriverCapabilitiesRequest():
    case PoolGetStateJsonRequest():
      sendPort.send(AuditPayloadResponse(id, error: error));
    case GetVersionRequest():
      sendPort.send(VersionResponse(id));
    case GetMetricsRequest():
      sendPort.send(MetricsResponse(id, error: error));
    case GetErrorRequest():
      sendPort.send(GetErrorResponse(id, error));
    case GetStructuredErrorRequest():
      sendPort.send(StructuredErrorResponse(id, message: error, error: error));
    case DetectDriverRequest():
      sendPort.send(DetectDriverResponse(id, null));
    case AuditGetEventsRequest():
    case AuditGetStatusRequest():
    case MetadataCacheStatsRequest():
      sendPort.send(AuditPayloadResponse(id, error: error));
    case GetCacheMetricsRequest():
      sendPort.send(CacheMetricsResponse(id, error: error));
    case ClearCacheRequest():
      sendPort.send(ClearCacheResponse(id, error: error));
  }
}

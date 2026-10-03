library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/native_call_context.dart';
import 'package:odbc_fast/infrastructure/native/errors/native_execution_stage.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/isolate/worker_failure_snapshot.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';

part 'worker_isolate_helpers.dart';
part 'worker_isolate_pool.dart';
part 'worker_isolate_query.dart';
part 'worker_isolate_stream.dart';
part 'worker_isolate_transaction.dart';

/// Shared dispatch state for worker isolate mixins.
abstract class _WorkerIsolateState {
  QueryResponse queryDataResponse(int requestId, Uint8List data);
  StreamFetchResponse streamDataResponse({
    required int requestId,
    required bool success,
    required Uint8List? data,
    required bool hasMore,
    String? error,
  });
}

/// Worker request dispatcher composed from domain mixins.
final _workerDispatcher = _WorkerDispatcher();

class _WorkerDispatcher extends _WorkerIsolateState
    with
        _WorkerIsolateHelpers,
        _WorkerIsolateQuery,
        _WorkerIsolatePool,
        _WorkerIsolateStream,
        _WorkerIsolateTransaction {}

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
  } on Object catch (e, st) {
    mainSendPort.send(
      InitializeResponse(
        0,
        success: false,
        failure: WorkerFailureSnapshot(
          message: 'The native library is unavailable',
          operation: 'initialize',
          requestId: 0,
          code: OdbcErrorCode.environmentUnavailable,
          cause: e.toString(),
          stackTrace: st.toString(),
        ),
      ),
    );
    // Close the port so the main isolate detects the channel death instead
    // of having pending requests hang until timeout.
    receivePort.close();
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

/// Dispatches one [WorkerRequest] synchronously (unit tests only).
@visibleForTesting
void handleWorkerRequestForTesting(
  WorkerRequest request,
  SendPort sendPort,
  NativeOdbcConnection conn,
) =>
    _handleRequest(request, sendPort, conn);

void _handleRequest(
  WorkerRequest request,
  SendPort sendPort,
  NativeOdbcConnection conn,
) =>
    NativeCallContext.capture(
      () {
        NativeCallContext.current?.resetInvocation();
        _dispatchRequest(request, sendPort, conn);
      },
      nativeConnectionId: _requestConnection(
        request,
        _workerResources[conn] ??= _WorkerResources(),
      ),
    );

void _dispatchRequest(
  WorkerRequest request,
  SendPort sendPort,
  NativeOdbcConnection conn,
) {
  try {
    final resources = _workerResources[conn] ??= _WorkerResources();
    final connection = _requestConnection(request, resources);
    final blocked = connection != null &&
        (resources.uncertainConnections.contains(connection) ||
            resources.uncertainTransactions
                .any((id) => resources.transactions[id] == connection) ||
            resources.uncertainXa.any((id) => resources.xa[id] == connection));
    if (blocked &&
        request is! DisconnectRequest &&
        request is! GetStructuredErrorForConnectionRequest &&
        request is! XaRecoverRequest &&
        request is! GetErrorRequest &&
        request is! GetStructuredErrorRequest) {
      throw const QueryError(
        message: 'The transaction outcome is not confirmed',
        details: OdbcErrorDetails(
          code: OdbcErrorCode.transaction,
          outcomeUnknown: true,
        ),
      );
    }
    switch (request) {
      case InitializeRequest():
      case SetLogLevelRequest():
      case ValidateConnectionStringRequest():
      case GetDriverCapabilitiesRequest():
      case GetConnectionDbmsInfoRequest():
      case ConnectRequest():
      case DisconnectRequest():
      case GetVersionRequest():
      case GetMetricsRequest():
      case GetCacheMetricsRequest():
      case ClearCacheRequest():
      case MetadataCacheEnableRequest():
      case MetadataCacheStatsRequest():
      case MetadataCacheClearRequest():
      case GetErrorRequest():
      case DetectDriverRequest():
      case GetStructuredErrorRequest():
      case GetStructuredErrorForConnectionRequest():
      case AuditEnableRequest():
      case AuditGetEventsRequest():
      case AuditGetStatusRequest():
      case AuditClearRequest():
        _workerDispatcher.dispatchHelpers(request, sendPort, conn);

      case ExecuteQueryParamsRequest():
      case ExecuteQueryMultiRequest():
      case ExecuteQueryMultiParamsRequest():
      case PrepareRequest():
      case ExecutePreparedRequest():
      case CancelStatementRequest():
      case CloseStatementRequest():
      case ClearAllStatementsRequest():
      case BulkInsertArrayRequest():
      case BulkInsertParallelRequest():
      case CatalogTablesRequest():
      case CatalogColumnsRequest():
      case CatalogTypeInfoRequest():
      case CatalogPrimaryKeysRequest():
      case CatalogForeignKeysRequest():
      case CatalogIndexesRequest():
      case ExecuteAsyncStartRequest():
      case ExecuteAsyncStartParamsRequest():
      case AsyncPollRequest():
      case AsyncGetResultRequest():
      case AsyncCancelRequest():
      case AsyncFreeRequest():
        _workerDispatcher.dispatchQuery(request, sendPort, conn);

      case BeginTransactionRequest():
      case CommitTransactionRequest():
      case RollbackTransactionRequest():
      case SavepointCreateRequest():
      case SavepointRollbackRequest():
      case SavepointReleaseRequest():
      case XaStartRequest():
      case XaIdRequest():
      case XaRecoverRequest():
      case XaResumePreparedRequest():
        _workerDispatcher.dispatchTransaction(request, sendPort, conn);

      case StreamStartRequest():
      case StreamStartBatchedRequest():
      case StreamStartAsyncRequest():
      case StreamMultiStartBatchedRequest():
      case StreamMultiStartAsyncRequest():
      case StreamPollAsyncRequest():
      case StreamPollFetchRequest():
      case StreamFetchRequest():
      case StreamCancelRequest():
      case StreamCloseRequest():
        _workerDispatcher.dispatchStream(request, sendPort, conn);

      case PoolCreateRequest():
      case PoolGetConnectionRequest():
      case PoolReleaseConnectionRequest():
      case PoolHealthCheckRequest():
      case PoolGetStateRequest():
      case PoolGetStateJsonRequest():
      case PoolSetSizeRequest():
      case PoolCloseRequest():
        _workerDispatcher.dispatchPool(request, sendPort, conn);
    }
  } on Object catch (e, st) {
    _sendWorkerResponse(
      request,
      sendPort,
      conn,
      buildWorkerErrorResponse(request, e.toString()),
      cause: e,
      stackTrace: st,
    );
  }
}

void _sendWorkerResponse(
  WorkerRequest request,
  SendPort sendPort,
  NativeOdbcConnection conn,
  WorkerResponse response, {
  Object? cause,
  StackTrace? stackTrace,
}) {
  final failed = cause != null ||
      switch (response) {
        BoolResponse(:final value) => !value,
        InitializeResponse(:final success) => !success,
        ConnectResponse(:final connectionId) => connectionId == 0,
        IntResponse(:final value) => switch (request) {
            XaIdRequest() => value != 0,
            AsyncPollRequest() || StreamPollAsyncRequest() => value < 0,
            BulkInsertArrayRequest() ||
            BulkInsertParallelRequest() ||
            ClearAllStatementsRequest() =>
              value < 0,
            _ => value == 0,
          },
        QueryResponse(:final error, :final hasData) =>
          error != null || !hasData,
        StreamFetchResponse(:final success) => !success,
        StreamPollFetchResponse(:final status) => status < 0,
        AuditPayloadResponse(:final error) => error != null,
        PoolStateResponse(:final error) => error != null,
        XaRecoverResponse(:final error) => error != null,
        _ => false,
      };
  final resources = _workerResources[conn] ??= _WorkerResources();
  if (!failed || response.failure != null) {
    _recordWorkerResources(request, response, resources);
    sendPort.send(
      WorkerReply(
        response,
        response.failure,
        executionStage: NativeCallContext.current?.executionStage,
      ),
    );
    return;
  }
  final connectionId = _requestConnection(request, resources);
  final known = switch (response) {
    QueryResponse(:final error) ||
    ConnectResponse(:final error) ||
    StreamFetchResponse(:final error) ||
    StreamPollFetchResponse(:final error) ||
    AuditPayloadResponse(:final error) =>
      error,
    _ => null,
  };
  final captured =
      NativeCallContext.takeFailure() ?? (cause is OdbcError ? cause : null);
  var message = captured?.message ?? known;
  var sqlState = captured?.sqlState;
  var nativeCode = captured?.nativeCode;
  String? secondary;
  if (cause == null && captured == null) {
    try {
      final structured = connectionId == null
          ? conn.getStructuredError()
          : conn.getStructuredErrorForConnection(connectionId);
      if (structured != null) {
        message ??= structured.message;
        sqlState = structured.sqlStateString;
        nativeCode = structured.nativeCode;
      }
      message ??= conn.getError();
    } on Object catch (error) {
      secondary = error.toString();
    }
  }
  if (message == null ||
      message.trim().isEmpty ||
      message.trim() == 'No error') {
    message = 'Failed to complete ${request.type.name}';
  }
  final snapshot = WorkerFailureSnapshot(
    message: message,
    operation: request.type.name,
    requestId: request.requestId,
    connectionId: connectionId,
    sqlState: sqlState,
    nativeCode: nativeCode,
    code: ((response is IntResponse &&
                response.value == -2 &&
                (request is AsyncPollRequest ||
                    request is StreamPollAsyncRequest)) ||
            (response is StreamPollFetchResponse && response.status == -2))
        ? OdbcErrorCode.cancelled
        : captured?.code ??
            (cause is FormatException
                ? OdbcErrorCode.protocol
                : cause != null
                    ? OdbcErrorCode.internal
                    : captured?.code ??
                        switch (request) {
                          InitializeRequest() =>
                            OdbcErrorCode.environmentUnavailable,
                          ConnectRequest() ||
                          DisconnectRequest() ||
                          PoolGetConnectionRequest() =>
                            OdbcErrorCode.connection,
                          CommitTransactionRequest() ||
                          RollbackTransactionRequest() ||
                          XaIdRequest() =>
                            OdbcErrorCode.transaction,
                          StreamCancelRequest() ||
                          StreamCloseRequest() ||
                          AsyncFreeRequest() =>
                            OdbcErrorCode.cleanup,
                          _ => OdbcErrorCode.query,
                        }),
    kind: captured == null ? null : WorkerFailureSnapshot.kindOf(captured),
    rowsInsertedBeforeFailure: captured is BulkPartialFailureError
        ? captured.rowsInsertedBeforeFailure
        : null,
    failedChunks:
        captured is BulkPartialFailureError ? captured.failedChunks : null,
    bulkDetail: captured is BulkPartialFailureError ? captured.detail : null,
    cause: captured?.details.cause?.toString() ?? cause?.toString(),
    stackTrace:
        stackTrace?.toString() ?? captured?.details.stackTrace?.toString(),
    outcomeUnknown: (captured?.details.outcomeUnknown ?? false) ||
        (request is XaIdRequest &&
            NativeCallContext.current?.executionStage !=
                NativeExecutionStage.notStarted &&
            (request.type == RequestType.xaCommitPrepared ||
                request.type == RequestType.xaCommitOnePhase)) ||
        (cause != null &&
            NativeCallContext.current?.executionStage !=
                NativeExecutionStage.notStarted),
    secondaryErrors: [
      for (final error in captured?.details.secondaryErrors ?? <OdbcError>[])
        WorkerFailureSnapshot.fromError(error, requestId: request.requestId),
    ],
    secondary: secondary,
    executionStage: NativeCallContext.current?.executionStage,
  );
  _recordWorkerResources(request, response, resources);
  switch (response) {
    case QueryResponse():
      sendPort.send(response.withFailure(snapshot));
    case IntResponse(:final value):
      sendPort.send(IntResponse(response.requestId, value, failure: snapshot));
    case BoolResponse(:final value, :final completionStatus):
      sendPort.send(
        BoolResponse(
          response.requestId,
          value: value,
          completionStatus: completionStatus,
          failure: snapshot,
        ),
      );
    case ConnectResponse(:final connectionId, :final error):
      sendPort.send(
        ConnectResponse(
          response.requestId,
          connectionId,
          error: error,
          failure: snapshot,
        ),
      );
    case InitializeResponse(:final success):
      sendPort.send(
        InitializeResponse(
          response.requestId,
          success: success,
          failure: snapshot,
        ),
      );
    default:
      sendPort.send(WorkerReply(response, snapshot));
  }
}

final _workerResources = Expando<_WorkerResources>();

class _WorkerResources {
  final pools = <int, int>{};
  final transactions = <int, int>{};
  final xa = <int, int>{};
  final statements = <int, int>{};
  final streams = <int, int>{};
  final asyncRequests = <int, int>{};
  final uncertainTransactions = <int>{};
  final uncertainXa = <int>{};
  final uncertainConnections = <int>{};
}

int? _requestConnection(WorkerRequest request, _WorkerResources resources) =>
    switch (request) {
      GetConnectionDbmsInfoRequest(:final connectionId) ||
      DisconnectRequest(:final connectionId) ||
      GetStructuredErrorForConnectionRequest(:final connectionId) ||
      PoolReleaseConnectionRequest(:final connectionId) ||
      ExecuteQueryParamsRequest(:final connectionId) ||
      ExecuteQueryMultiRequest(:final connectionId) ||
      ExecuteQueryMultiParamsRequest(:final connectionId) ||
      PrepareRequest(:final connectionId) ||
      BulkInsertArrayRequest(:final connectionId) ||
      CatalogTablesRequest(:final connectionId) ||
      CatalogColumnsRequest(:final connectionId) ||
      CatalogTypeInfoRequest(:final connectionId) ||
      CatalogPrimaryKeysRequest(:final connectionId) ||
      CatalogForeignKeysRequest(:final connectionId) ||
      CatalogIndexesRequest(:final connectionId) ||
      ExecuteAsyncStartRequest(:final connectionId) ||
      ExecuteAsyncStartParamsRequest(:final connectionId) ||
      StreamStartRequest(:final connectionId) ||
      StreamStartBatchedRequest(:final connectionId) ||
      StreamStartAsyncRequest(:final connectionId) ||
      StreamMultiStartBatchedRequest(:final connectionId) ||
      StreamMultiStartAsyncRequest(:final connectionId) ||
      BeginTransactionRequest(:final connectionId) ||
      XaStartRequest(:final connectionId) ||
      XaRecoverRequest(:final connectionId) ||
      XaResumePreparedRequest(:final connectionId) =>
        connectionId,
      ExecutePreparedRequest(:final stmtId) => resources.statements[stmtId],
      CancelStatementRequest(:final stmtId) => resources.statements[stmtId],
      CloseStatementRequest(:final stmtId) => resources.statements[stmtId],
      AsyncPollRequest(:final asyncRequestId) =>
        resources.asyncRequests[asyncRequestId],
      AsyncGetResultRequest(:final asyncRequestId) =>
        resources.asyncRequests[asyncRequestId],
      AsyncCancelRequest(:final asyncRequestId) =>
        resources.asyncRequests[asyncRequestId],
      AsyncFreeRequest(:final asyncRequestId) =>
        resources.asyncRequests[asyncRequestId],
      StreamPollAsyncRequest(:final streamId) => resources.streams[streamId],
      StreamPollFetchRequest(:final streamId) => resources.streams[streamId],
      StreamFetchRequest(:final streamId) => resources.streams[streamId],
      StreamCancelRequest(:final streamId) => resources.streams[streamId],
      StreamCloseRequest(:final streamId) => resources.streams[streamId],
      CommitTransactionRequest(:final txnId) => resources.transactions[txnId],
      RollbackTransactionRequest(:final txnId) => resources.transactions[txnId],
      SavepointCreateRequest(:final txnId) => resources.transactions[txnId],
      SavepointRollbackRequest(:final txnId) => resources.transactions[txnId],
      SavepointReleaseRequest(:final txnId) => resources.transactions[txnId],
      XaIdRequest(:final xaId) => resources.xa[xaId],
      _ => null,
    };

void _recordWorkerResources(
  WorkerRequest request,
  WorkerResponse response,
  _WorkerResources resources,
) {
  final connection = _requestConnection(request, resources);
  if (request is PoolGetConnectionRequest &&
      response is IntResponse &&
      response.value > 0) {
    resources.pools[response.value] = request.poolId;
  }
  if (response is IntResponse && response.value > 0 && connection != null) {
    final target = switch (request) {
      BeginTransactionRequest() => resources.transactions,
      XaStartRequest() || XaResumePreparedRequest() => resources.xa,
      PrepareRequest() => resources.statements,
      StreamStartRequest() ||
      StreamStartBatchedRequest() ||
      StreamStartAsyncRequest() ||
      StreamMultiStartBatchedRequest() ||
      StreamMultiStartAsyncRequest() =>
        resources.streams,
      ExecuteAsyncStartRequest() ||
      ExecuteAsyncStartParamsRequest() =>
        resources.asyncRequests,
      _ => null,
    };
    target?[response.value] = connection;
  }
  switch (request) {
    case CommitTransactionRequest(:final txnId) ||
          RollbackTransactionRequest(:final txnId):
      if (response is BoolResponse &&
          (response.completionStatus == 0 || response.completionStatus == 1)) {
        resources.transactions.remove(txnId);
        resources.uncertainTransactions.remove(txnId);
        if (response.completionStatus == 1 && connection != null) {
          resources.uncertainConnections.add(connection);
        }
      } else if (response is BoolResponse && response.completionStatus == 2) {
        resources.uncertainTransactions.remove(txnId);
      } else if (NativeCallContext.current?.executionStage !=
          NativeExecutionStage.notStarted) {
        resources.uncertainTransactions.add(txnId);
      }
    case XaIdRequest(:final xaId):
      if (response is IntResponse &&
          response.value == 0 &&
          (request.type == RequestType.xaCommitPrepared ||
              request.type == RequestType.xaCommitOnePhase ||
              request.type == RequestType.xaRollbackPrepared ||
              request.type == RequestType.xaRollbackActive)) {
        resources.xa.remove(xaId);
        resources.uncertainXa.remove(xaId);
      } else if (NativeCallContext.current?.executionStage !=
              NativeExecutionStage.notStarted &&
          (NativeCallContext.current?.executionStage ==
                  NativeExecutionStage.started ||
              request.type == RequestType.xaCommitPrepared ||
              request.type == RequestType.xaCommitOnePhase)) {
        resources.uncertainXa.add(xaId);
      }
    case CloseStatementRequest(:final stmtId):
      if (response is BoolResponse && response.value) {
        resources.statements.remove(stmtId);
      }
    case StreamCloseRequest(:final streamId):
      if (response is BoolResponse && response.value) {
        resources.streams.remove(streamId);
      }
    case AsyncFreeRequest(:final asyncRequestId):
      if (response is BoolResponse && response.value) {
        resources.asyncRequests.remove(asyncRequestId);
      }
    case PoolCloseRequest(:final poolId):
      if (response is BoolResponse && response.value) {
        final connections = resources.pools.entries
            .where((e) => e.value == poolId)
            .map((e) => e.key)
            .toSet();
        resources.pools.removeWhere((_, id) => id == poolId);
        resources.uncertainConnections.removeAll(connections);
        for (final map in [
          resources.transactions,
          resources.xa,
          resources.statements,
          resources.streams,
          resources.asyncRequests,
        ]) {
          map.removeWhere((_, id) => connections.contains(id));
        }
      }
    case DisconnectRequest(:final connectionId) ||
          PoolReleaseConnectionRequest(:final connectionId):
      if (response is BoolResponse && response.value) {
        resources.uncertainConnections.remove(connectionId);
        resources.pools.remove(connectionId);
        for (final map in [
          resources.transactions,
          resources.xa,
          resources.statements,
          resources.streams,
          resources.asyncRequests,
        ]) {
          map.removeWhere((key, value) => value == connectionId);
        }
      }
    default:
      break;
  }
  resources.uncertainTransactions
      .removeWhere((id) => !resources.transactions.containsKey(id));
  resources.uncertainXa.removeWhere((id) => !resources.xa.containsKey(id));
}

String _workerError(NativeOdbcConnection conn) {
  final captured = NativeCallContext.current?.failure;
  if (captured != null) return captured.message;
  try {
    return conn.getError();
  } on Object catch (error, stack) {
    final primary = QueryError(
      message: 'The native operation failed',
      details: OdbcErrorDetails(
        secondaryErrors: [
          QueryError(
            message: 'Failed to collect native diagnostic',
            details: OdbcErrorDetails(
              code: OdbcErrorCode.internal,
              operation: 'collectDiagnostic',
              cause: error,
              stackTrace: stack,
            ),
          ),
        ],
      ),
    );
    NativeCallContext.record(primary);
    return primary.message;
  }
}

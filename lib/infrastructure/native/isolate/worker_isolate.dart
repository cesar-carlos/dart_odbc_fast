library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';

part 'worker_isolate_helpers.dart';
part 'worker_isolate_query.dart';
part 'worker_isolate_pool.dart';
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
  } on Object catch (_) {
    mainSendPort.send(const InitializeResponse(0, success: false));
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
) {
  try {
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
        _workerDispatcher.dispatchTransaction(request, sendPort, conn);

      case StreamStartRequest():
      case StreamStartBatchedRequest():
      case StreamStartAsyncRequest():
      case StreamMultiStartBatchedRequest():
      case StreamMultiStartAsyncRequest():
      case StreamPollAsyncRequest():
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
    sendWorkerErrorResponse(request, sendPort, '$e\n$st');
  }
}

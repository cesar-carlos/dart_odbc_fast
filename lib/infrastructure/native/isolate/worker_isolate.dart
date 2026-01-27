import 'dart:isolate';

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
  } catch (e) {
    mainSendPort.send(InitializeResponse(0, false));
    return;
  }

  receivePort.listen((Object? message) {
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
        sendPort.send(InitializeResponse(request.requestId, ok));

      case ConnectRequest():
        try {
          final connId = conn.connect(request.connectionString);
          if (connId == 0) {
            final err = conn.getError();
            sendPort.send(ConnectResponse(
              request.requestId,
              0,
              error: err.isNotEmpty ? err : 'Connect failed',
            ));
          } else {
            sendPort.send(ConnectResponse(request.requestId, connId));
          }
        } catch (e) {
          sendPort.send(ConnectResponse(
            request.requestId,
            0,
            error: e.toString(),
          ));
        }

      case DisconnectRequest():
        final ok = conn.disconnect(request.connectionId);
        sendPort.send(BoolResponse(request.requestId, ok));

      case ExecuteQueryParamsRequest():
        final data = conn.executeQueryParamsRaw(
          request.connectionId,
          request.sql,
          request.serializedParams.isEmpty ? null : request.serializedParams,
        );
        if (data != null && data.isNotEmpty) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          final err = conn.getError();
          sendPort.send(QueryResponse(
            request.requestId,
            error: err.isNotEmpty ? err : 'Query failed',
          ));
        }

      case ExecuteQueryMultiRequest():
        final data = conn.executeQueryMulti(request.connectionId, request.sql);
        if (data != null && data.isNotEmpty) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          final err = conn.getError();
          sendPort.send(QueryResponse(
            request.requestId,
            error: err.isNotEmpty ? err : 'Query failed',
          ));
        }

      case BeginTransactionRequest():
        final txnId = conn.beginTransaction(
          request.connectionId,
          request.isolationLevel,
        );
        sendPort.send(IntResponse(request.requestId, txnId));

      case CommitTransactionRequest():
        final ok = conn.commitTransaction(request.txnId);
        sendPort.send(BoolResponse(request.requestId, ok));

      case RollbackTransactionRequest():
        final ok = conn.rollbackTransaction(request.txnId);
        sendPort.send(BoolResponse(request.requestId, ok));

      case PrepareRequest():
        final stmtId = conn.prepare(
          request.connectionId,
          request.sql,
          timeoutMs: request.timeoutMs,
        );
        sendPort.send(IntResponse(request.requestId, stmtId));

      case ExecutePreparedRequest():
        final bytes = request.serializedParams.isEmpty
            ? null
            : request.serializedParams;
        final data = conn.executePreparedRaw(request.stmtId, bytes);
        if (data != null && data.isNotEmpty) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          final err = conn.getError();
          sendPort.send(QueryResponse(
            request.requestId,
            error: err.isNotEmpty ? err : 'Execute prepared failed',
          ));
        }

      case CloseStatementRequest():
        final ok = conn.closeStatement(request.stmtId);
        sendPort.send(BoolResponse(request.requestId, ok));

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
        sendPort.send(BoolResponse(request.requestId, ok));

      case PoolHealthCheckRequest():
        final ok = conn.poolHealthCheck(request.poolId);
        sendPort.send(BoolResponse(request.requestId, ok));

      case PoolGetStateRequest():
        final state = conn.poolGetState(request.poolId);
        if (state != null) {
          sendPort.send(PoolStateResponse(
            request.requestId,
            size: state.size,
            idle: state.idle,
          ));
        } else {
          sendPort.send(PoolStateResponse(
            request.requestId,
            error: conn.getError(),
          ));
        }

      case PoolCloseRequest():
        final ok = conn.poolClose(request.poolId);
        sendPort.send(BoolResponse(request.requestId, ok));

      case BulkInsertArrayRequest():
        final rows = conn.bulkInsertArray(
          request.connectionId,
          request.table,
          request.columns,
          request.dataBuffer,
          request.rowCount,
        );
        sendPort.send(IntResponse(request.requestId, rows));

      case GetMetricsRequest():
        final m = conn.getMetrics();
        if (m != null) {
          sendPort.send(MetricsResponse(
            request.requestId,
            queryCount: m.queryCount,
            errorCount: m.errorCount,
            uptimeSecs: m.uptimeSecs,
            totalLatencyMillis: m.totalLatencyMillis,
            avgLatencyMillis: m.avgLatencyMillis,
          ));
        } else {
          sendPort.send(MetricsResponse(
            request.requestId,
            error: conn.getError(),
          ));
        }

      case CatalogTablesRequest():
        final data = conn.catalogTables(
          request.connectionId,
          catalog: request.catalog,
          schema: request.schema,
        );
        if (data != null && data.isNotEmpty) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          sendPort.send(QueryResponse(
            request.requestId,
            error: conn.getError(),
          ));
        }

      case CatalogColumnsRequest():
        final data = conn.catalogColumns(
          request.connectionId,
          request.table,
        );
        if (data != null && data.isNotEmpty) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          sendPort.send(QueryResponse(
            request.requestId,
            error: conn.getError(),
          ));
        }

      case CatalogTypeInfoRequest():
        final data = conn.catalogTypeInfo(request.connectionId);
        if (data != null && data.isNotEmpty) {
          sendPort.send(QueryResponse(request.requestId, data: data));
        } else {
          sendPort.send(QueryResponse(
            request.requestId,
            error: conn.getError(),
          ));
        }

      case GetErrorRequest():
        final msg = conn.getError();
        sendPort.send(GetErrorResponse(request.requestId, msg));

      case GetStructuredErrorRequest():
        final se = conn.getStructuredError();
        if (se != null) {
          sendPort.send(StructuredErrorResponse(
            request.requestId,
            message: se.message,
            sqlStateString: se.sqlStateString,
            nativeCode: se.nativeCode,
          ));
        } else {
          sendPort.send(StructuredErrorResponse(request.requestId));
        }
    }
  } catch (e, st) {
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
      sendPort.send(InitializeResponse(id, false));
    case ConnectRequest():
      sendPort.send(ConnectResponse(id, 0, error: error));
    case DisconnectRequest():
    case CloseStatementRequest():
    case PoolReleaseConnectionRequest():
    case PoolHealthCheckRequest():
    case PoolCloseRequest():
    case CommitTransactionRequest():
    case RollbackTransactionRequest():
      sendPort.send(BoolResponse(id, false));
    case ExecuteQueryParamsRequest():
    case ExecuteQueryMultiRequest():
    case ExecutePreparedRequest():
    case CatalogTablesRequest():
    case CatalogColumnsRequest():
    case CatalogTypeInfoRequest():
      sendPort.send(QueryResponse(id, error: error));
    case BeginTransactionRequest():
    case PrepareRequest():
    case PoolCreateRequest():
    case PoolGetConnectionRequest():
      sendPort.send(IntResponse(id, 0));
    case BulkInsertArrayRequest():
      sendPort.send(IntResponse(id, -1));
    case PoolGetStateRequest():
      sendPort.send(PoolStateResponse(id, error: error));
    case GetMetricsRequest():
      sendPort.send(MetricsResponse(id, error: error));
    case GetErrorRequest():
      sendPort.send(GetErrorResponse(id, error));
    case GetStructuredErrorRequest():
      sendPort.send(StructuredErrorResponse(id, message: error, error: error));
  }
}


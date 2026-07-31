part of 'worker_isolate.dart';

mixin _WorkerIsolateQuery on _WorkerIsolateState {
  void dispatchQuery(
    WorkerRequest request,
    SendPort sendPort,
    NativeOdbcConnection conn,
  ) {
    switch (request) {
      case ExecuteQueryParamsRequest():
        final data = conn.executeQueryParamsRaw(
          request.connectionId,
          request.sql,
          request.serializedParams.isEmpty ? null : request.serializedParams,
          maxBufferBytes: request.maxResultBufferBytes,
          initialBufferBytes: request.initialResultBufferBytes,
          resultEncoding: request.resultEncoding,
        );
        if (data != null) {
          sendPort.send(queryDataResponse(request.requestId, data));
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
          initialBufferBytes: request.initialResultBufferBytes,
        );
        if (data != null) {
          sendPort.send(queryDataResponse(request.requestId, data));
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
          initialBufferBytes: request.initialResultBufferBytes,
        );
        if (data != null) {
          sendPort.send(queryDataResponse(request.requestId, data));
        } else {
          final err = conn.getError();
          final message = err.isNotEmpty && err != 'No error'
              ? err
              : 'Multi-result query (with params) failed '
                  '(native returned no data)';
          sendPort.send(QueryResponse(request.requestId, error: message));
        }

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
          initialBufferBytes: request.initialResultBufferBytes,
        );
        if (data != null) {
          sendPort.send(queryDataResponse(request.requestId, data));
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

      case CatalogTablesRequest():
        final data = conn.catalogTables(
          request.connectionId,
          catalog: request.catalog,
          schema: request.schema,
          initialBufferBytes: request.initialBufferBytes,
          maxBufferBytes: request.maxBufferBytes,
        );
        if (data != null) {
          sendPort.send(queryDataResponse(request.requestId, data));
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
          initialBufferBytes: request.initialBufferBytes,
          maxBufferBytes: request.maxBufferBytes,
        );
        if (data != null) {
          sendPort.send(queryDataResponse(request.requestId, data));
        } else {
          final err = conn.getError();
          final message = err.isNotEmpty && err != 'No error'
              ? err
              : 'Catalog columns failed (native returned no data; check connection/driver state)';
          sendPort.send(QueryResponse(request.requestId, error: message));
        }

      case CatalogTypeInfoRequest():
        final data = conn.catalogTypeInfo(
          request.connectionId,
          initialBufferBytes: request.initialBufferBytes,
          maxBufferBytes: request.maxBufferBytes,
        );
        if (data != null) {
          sendPort.send(queryDataResponse(request.requestId, data));
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
          initialBufferBytes: request.initialBufferBytes,
          maxBufferBytes: request.maxBufferBytes,
        );
        if (data != null) {
          sendPort.send(queryDataResponse(request.requestId, data));
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
          initialBufferBytes: request.initialBufferBytes,
          maxBufferBytes: request.maxBufferBytes,
        );
        if (data != null) {
          sendPort.send(queryDataResponse(request.requestId, data));
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
          initialBufferBytes: request.initialBufferBytes,
          maxBufferBytes: request.maxBufferBytes,
        );
        if (data != null) {
          sendPort.send(queryDataResponse(request.requestId, data));
        } else {
          final err = conn.getError();
          final message = err.isNotEmpty && err != 'No error'
              ? err
              : 'Catalog indexes failed (native returned no data; check connection/driver state)';
          sendPort.send(QueryResponse(request.requestId, error: message));
        }

      case ExecuteAsyncStartRequest():
        final asyncRequestId = conn.executeAsyncStart(
          request.connectionId,
          request.sql,
        );
        sendPort.send(IntResponse(request.requestId, asyncRequestId ?? 0));

      case ExecuteAsyncStartParamsRequest():
        final encoding = switch (request.resultEncodingWire) {
          1 => ResultEncoding.columnar,
          2 => ResultEncoding.columnarCompressed,
          _ => ResultEncoding.rowMajor,
        };
        final asyncRequestId = conn.executeAsyncStartParams(
          request.connectionId,
          request.sql,
          request.serializedParams.isEmpty ? null : request.serializedParams,
          resultEncoding: encoding,
        );
        sendPort.send(IntResponse(request.requestId, asyncRequestId ?? 0));

      case AsyncPollRequest():
        final status = conn.asyncPoll(request.asyncRequestId);
        sendPort.send(IntResponse(request.requestId, status ?? -1));

      case AsyncGetResultRequest():
        final data = conn.asyncGetResult(
          request.asyncRequestId,
          maxBufferBytes: request.maxResultBufferBytes,
          initialBufferBytes: request.initialResultBufferBytes,
        );
        if (data != null) {
          sendPort.send(queryDataResponse(request.requestId, data));
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

      default:
        throw StateError('Unexpected query request: ${request.type}');
    }
  }
}

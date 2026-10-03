part of 'async_native_odbc_connection.dart';

/// Contains identifiers only; never retain SQL or connection strings here.
class _AbandonedRequest {
  _AbandonedRequest({
    required this.type,
    required this.requestId,
    required this.generation,
    required this.workerId,
    this.connectionId,
    this.resourceId,
    this.poolId,
    this.xidKey,
    this.safeRequest,
    this.context,
    this.connectionLifetime,
    this.maintenance = false,
  });

  final RequestType type;
  final int requestId;
  final int generation;
  final int workerId;
  final int? connectionId;
  final int? resourceId;
  final int? poolId;
  final String? xidKey;
  final WorkerRequest? safeRequest;
  final NativeCallContext? context;
  final Object? connectionLifetime;
  int? allocatedResourceId;
  final bool maintenance;
  OdbcError? timeout;
  bool responded = false;
}

extension _Reconciliation on _AsyncOdbcState {
  void _diagnose(OdbcError error) {
    final callback = onDiagnostic;
    if (callback == null) {
      AppLogger.warning(error.userMessage, error, error.details.stackTrace);
      return;
    }
    try {
      callback(error);
    } on Object catch (cause, stack) {
      final secondary = translateOdbcError(
        cause,
        operation: 'onDiagnostic',
        stackTrace: stack,
      );
      AppLogger.warning(
        'The diagnostic callback failed',
        error.withSecondary(secondary),
        stack,
      );
    }
  }

  String _xaResumeKey(
    int connection,
    int format,
    Uint8List gtrid,
    Uint8List bqual,
  ) =>
      '$_generation:$connection:$format:${gtrid.join(',')}:${bqual.join(',')}';
}

mixin _AsyncWorkerReconciliation on _AsyncOdbcState, _AsyncWorkerDispatch {
  int? _requestConnectionId(WorkerRequest request) => switch (request) {
        DisconnectRequest(:final connectionId) ||
        PoolReleaseConnectionRequest(:final connectionId) ||
        GetConnectionDbmsInfoRequest(:final connectionId) ||
        GetStructuredErrorForConnectionRequest(:final connectionId) ||
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
        CommitTransactionRequest(:final txnId) ||
        RollbackTransactionRequest(:final txnId) ||
        SavepointCreateRequest(:final txnId) ||
        SavepointRollbackRequest(:final txnId) ||
        SavepointReleaseRequest(:final txnId) =>
          _transactionConnectionById[txnId],
        XaIdRequest(:final xaId) => _xaConnectionById[xaId],
        ExecutePreparedRequest(:final stmtId) ||
        CloseStatementRequest(:final stmtId) ||
        CancelStatementRequest(:final stmtId) =>
          _statementConnectionById[stmtId],
        StreamFetchRequest(:final streamId) ||
        StreamPollFetchRequest(:final streamId) ||
        StreamPollAsyncRequest(:final streamId) ||
        StreamCloseRequest(:final streamId) ||
        StreamCancelRequest(:final streamId) =>
          _streamConnectionById[streamId],
        AsyncPollRequest(:final asyncRequestId) ||
        AsyncGetResultRequest(:final asyncRequestId) ||
        AsyncCancelRequest(:final asyncRequestId) ||
        AsyncFreeRequest(:final asyncRequestId) =>
          _asyncRequestConnectionById[asyncRequestId],
        _ => null,
      };

  @override
  _AbandonedRequest _describe(
    WorkerRequest request,
    _WorkerChannel worker, {
    bool maintenance = false,
  }) {
    final resource = switch (request) {
      CommitTransactionRequest(:final txnId) ||
      RollbackTransactionRequest(:final txnId) =>
        txnId,
      XaIdRequest(:final xaId) => xaId,
      _ => null,
    };
    final pool = switch (request) {
      PoolGetConnectionRequest(:final poolId) => poolId,
      _ => null,
    };
    final safe = switch (request) {
      CommitTransactionRequest() ||
      RollbackTransactionRequest() ||
      DisconnectRequest() ||
      PoolReleaseConnectionRequest() ||
      PoolCloseRequest() ||
      CloseStatementRequest() ||
      StreamCloseRequest() ||
      AsyncFreeRequest() ||
      XaIdRequest() =>
        request,
      _ => null,
    };
    return _AbandonedRequest(
      type: request.type,
      requestId: request.requestId,
      generation: worker.generation,
      workerId: worker.index,
      connectionId: _requestConnectionId(request),
      connectionLifetime:
          _nativeConnectionLifetimes[_requestConnectionId(request)],
      resourceId: resource,
      poolId: pool,
      safeRequest: safe,
      context: NativeCallContext.current,
      maintenance: maintenance,
      xidKey: request is XaResumePreparedRequest
          ? _xaResumeKey(
              request.connectionId,
              request.formatId,
              request.gtrid,
              request.bqual,
            )
          : null,
    );
  }

  @override
  void _validateRequest(WorkerRequest request) {
    final connection = _requestConnectionId(request);
    if (_deadConnections.contains(connection)) {
      throw WorkerCrashedError(
        message: 'The connection worker is unavailable',
        details: OdbcErrorDetails(
          code: OdbcErrorCode.workerInterrupted,
          operation: request.type.name,
          connectionId: connection?.toString(),
          outcomeUnknown: true,
        ),
      );
    }
    final blocked = connection != null &&
        (_quarantinedConnections.contains(connection) ||
            _blockedTransactions
                .any((id) => _transactionConnectionById[id] == connection) ||
            _blockedXa.any((id) => _xaConnectionById[id] == connection));
    if (!blocked ||
        request is DisconnectRequest ||
        request is GetStructuredErrorForConnectionRequest ||
        request is XaRecoverRequest) {
      return;
    }
    throw QueryError(
      message: 'The transaction or resource outcome is not confirmed',
      details: OdbcErrorDetails(
        code: OdbcErrorCode.transaction,
        operation: request.type.name,
        connectionId: connection.toString(),
        outcomeUnknown: true,
      ),
    );
  }

  void _abandonWorker(_WorkerChannel worker, AsyncError reason) {
    _deadConnections.addAll(
      _connectionWorkerById.entries
          .where((entry) => entry.value == worker.index)
          .map((entry) => entry.key),
    );
    for (final entry in {
      ...worker.requests.values,
      ...worker.abandoned.values,
    }) {
      final base = entry.timeout ?? reason.toOdbcError();
      final diagnostic = base.withDetails(
        base.details.copyWith(
          operation: entry.type.name,
          requestId: entry.requestId,
          workerId: worker.index,
          connectionId: entry.connectionId?.toString(),
          outcomeUnknown: true,
        ),
      );
      if (entry.context case final context?) {
        context.failure =
            context.failure?.withSecondary(diagnostic) ?? diagnostic;
      }
      _diagnose(diagnostic);
    }
    worker.abandoned.clear();
    worker.requests.clear();
    worker.failureSnapshots.clear();
    worker.executionStages.clear();
  }

  @override
  Future<void> _reconcileLate(
    _WorkerChannel worker,
    _AbandonedRequest entry,
    WorkerResponse response,
  ) async {
    if (entry.generation != _generation || worker.closed) return;
    final snapshot =
        worker.failureSnapshots.remove(entry.requestId) ?? response.failure;
    final stage = worker.executionStages.remove(entry.requestId) ??
        snapshot?.executionStage;
    final primary = entry.timeout!;
    try {
      final lifetimeValid = entry.connectionId == null ||
          identical(
            entry.connectionLifetime,
            _nativeConnectionLifetimes[entry.connectionId],
          );
      final safeRequest = entry.safeRequest;
      if (lifetimeValid && safeRequest != null) {
        _recordAffinity(safeRequest, response, worker);
      }
      final status = response is BoolResponse
          ? response.completionStatus ?? (response.value ? 0 : null)
          : response is IntResponse
              ? response.value
              : null;
      final context = entry.context;
      if (lifetimeValid && context != null) {
        context.executionStage = stage;
        context.onReconciled?.call(status);
      }
      if (lifetimeValid && entry.resourceId != null) {
        final id = entry.resourceId!;
        if (entry.type == RequestType.commitTransaction ||
            entry.type == RequestType.rollbackTransaction) {
          if (status == 0 ||
              status == 1 ||
              status == 2 ||
              stage == NativeExecutionStage.notStarted) {
            _blockedTransactions.remove(id);
          }
          if (status == 1 && entry.connectionId != null) {
            _quarantinedConnections.add(entry.connectionId!);
          }
        } else if (status == 0 || stage == NativeExecutionStage.notStarted) {
          _blockedXa.remove(id);
        }
      }
      final resource = response is ConnectResponse
          ? response.connectionId
          : response is IntResponse
              ? response.value
              : 0;
      if (resource > 0) {
        entry.allocatedResourceId = resource;
        if (!lifetimeValid && entry.type == RequestType.xaResumePrepared) {
          throw const QueryError(
            message: 'The prepared XA handle belongs to a closed connection',
            details: OdbcErrorDetails(
              code: OdbcErrorCode.cleanup,
              outcomeUnknown: true,
            ),
          );
        }
        await _compensate(worker, entry, resource);
      } else if (entry.type == RequestType.xaResumePrepared &&
          snapshot?.outcomeUnknown != true &&
          stage != NativeExecutionStage.started) {
        _pendingXaResume.remove(entry.xidKey);
      }
      worker.abandoned.remove(entry.requestId);
      if (!entry.maintenance) worker.finishRequest();
      worker.lateResponses++;
      _diagnose(
        primary.withDetails(
          primary.details.copyWith(
            outcomeUnknown: (snapshot?.outcomeUnknown ?? false) ||
                (stage != NativeExecutionStage.notStarted &&
                    (entry.resourceId != null && status != 0 && status != 2)),
            secondaryErrors:
                snapshot == null ? [] : [snapshot.toError(worker.index)],
          ),
        ),
      );
    } on Object catch (cause, stack) {
      if (entry.connectionId case final connection?) {
        if (entry.generation == _generation &&
            identical(
              entry.connectionLifetime,
              _nativeConnectionLifetimes[connection],
            )) {
          _quarantinedConnections.add(connection);
        }
      }
      worker.compensationFailures++;
      _diagnose(
        primary
            .withDetails(
              primary.details.copyWith(
                connectionId: entry.connectionId?.toString() ??
                    ((entry.type == RequestType.connect ||
                            entry.type == RequestType.poolGetConnection)
                        ? entry.allocatedResourceId?.toString()
                        : null),
                outcomeUnknown: true,
              ),
            )
            .withSecondary(
              translateOdbcError(
                cause,
                operation: 'reconcileCleanup',
                stackTrace: stack,
              ),
            ),
      );
    } finally {
      _drainBackpressureWaiters();
    }
  }

  Future<void> _compensate(
    _WorkerChannel worker,
    _AbandonedRequest entry,
    int resource,
  ) async {
    Future<void> send(WorkerRequest request) async {
      final response = await _sendRequestOnWorker<WorkerResponse>(
        worker,
        request,
        maintenance: true,
      );
      if (response.failure != null ||
          (response is BoolResponse && !response.value) ||
          (response is IntResponse && response.value != 0)) {
        throw response.failure?.toError(worker.index) ??
            const QueryError(
              message: 'The late resource could not be released',
              details: OdbcErrorDetails(
                code: OdbcErrorCode.cleanup,
                outcomeUnknown: true,
              ),
            );
      }
    }

    final cleanup = switch (entry.type) {
      RequestType.connect => DisconnectRequest(_nextRequestId(), resource),
      RequestType.poolCreate => PoolCloseRequest(_nextRequestId(), resource),
      RequestType.poolGetConnection =>
        PoolReleaseConnectionRequest(_nextRequestId(), resource),
      RequestType.prepare => CloseStatementRequest(_nextRequestId(), resource),
      RequestType.beginTransaction =>
        RollbackTransactionRequest(_nextRequestId(), resource),
      _ => null,
    };
    if (cleanup != null) {
      await send(cleanup);
      return;
    }
    final stream = entry.type == RequestType.streamStart ||
        entry.type == RequestType.streamStartBatched ||
        entry.type == RequestType.streamStartAsync ||
        entry.type == RequestType.streamMultiStartBatched ||
        entry.type == RequestType.streamMultiStartAsync;
    final asynchronous = entry.type == RequestType.executeAsyncStart ||
        entry.type == RequestType.executeAsyncStartParams;
    if (stream || asynchronous) {
      OdbcError? cancellation;
      try {
        await send(
          stream
              ? StreamCancelRequest(_nextRequestId(), resource)
              : AsyncCancelRequest(_nextRequestId(), resource),
        );
      } on Object catch (cause, stack) {
        cancellation = translateOdbcError(
          cause,
          operation: stream ? 'streamCancel' : 'asyncCancel',
          stackTrace: stack,
        );
      }
      try {
        await send(
          stream
              ? StreamCloseRequest(_nextRequestId(), resource)
              : AsyncFreeRequest(_nextRequestId(), resource),
        );
      } on Object catch (cause, stack) {
        final failure = translateOdbcError(
          cause,
          operation: stream ? 'streamClose' : 'asyncFree',
          stackTrace: stack,
        );
        throw cancellation?.withSecondary(failure) ?? failure;
      }
      if (cancellation != null) throw cancellation;
    } else if (entry.type == RequestType.xaStart) {
      await send(XaIdRequest(_nextRequestId(), RequestType.xaEnd, resource));
      await send(
        XaIdRequest(
          _nextRequestId(),
          RequestType.xaRollbackActive,
          resource,
        ),
      );
    } else if (entry.type == RequestType.xaResumePrepared) {
      _resumedXa[entry.xidKey!] = resource;
      _pendingXaResume.remove(entry.xidKey);
      _xaWorkerById[resource] = worker.index;
      _xaConnectionById[resource] = entry.connectionId!;
    }
  }
}

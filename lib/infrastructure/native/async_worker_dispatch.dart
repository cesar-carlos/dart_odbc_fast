part of 'async_native_odbc_connection.dart';

mixin _AsyncWorkerDispatch on _AsyncOdbcState {
  _AbandonedRequest _describe(
    WorkerRequest request,
    _WorkerChannel worker, {
    bool maintenance = false,
  });
  void _validateRequest(WorkerRequest request);
  Future<void> _reconcileLate(
    _WorkerChannel worker,
    _AbandonedRequest entry,
    WorkerResponse response,
  );

  Future<T> _sendRequest<T extends WorkerResponse>(
    WorkerRequest request,
  ) async {
    if (_workers.isEmpty) {
      throw StateError('Worker not initialized');
    }
    return _sendRequestOnWorker<T>(
      _resolveWorker(request),
      request,
      rerouteAfterBackpressure: _canRerouteAfterBackpressure(request),
    );
  }

  Future<T> _sendRequestOnWorker<T extends WorkerResponse>(
    _WorkerChannel worker,
    WorkerRequest request, {
    bool rerouteAfterBackpressure = false,
    bool maintenance = false,
  }) async {
    final queueStopwatch = Stopwatch()..start();
    final context = NativeCallContext.current;
    context?.resetInvocation();
    if (!maintenance) _validateRequest(request);
    final acquiredSlot =
        maintenance ? false : _acquireBackpressureSlot(request);
    final bool waitedForSlot;
    final bool reservedSlot;
    if (acquiredSlot is Future<bool>) {
      waitedForSlot = true;
      reservedSlot = await acquiredSlot;
    } else {
      waitedForSlot = false;
      reservedSlot = acquiredSlot;
    }
    if (worker.generation != _generation || _isShuttingDown) {
      if (reservedSlot) _releaseReservedBackpressureSlot();
      throw const AsyncError(
        code: AsyncErrorCode.workerTerminated,
        message: 'The worker generation changed while awaiting capacity',
      );
    }
    final queueWaitMicros = (queueStopwatch..stop()).elapsedMicroseconds;
    final targetWorker = waitedForSlot && rerouteAfterBackpressure
        ? _resolveWorker(request)
        : worker;
    final stopwatch = Stopwatch()..start();
    Completer<WorkerResponse>? completer;
    var slotReleased = false;
    var counted = false;
    try {
      if (reservedSlot) {
        _releaseReservedBackpressureSlot();
        slotReleased = true;
      }
      if (targetWorker.closed ||
          targetWorker.generation != _generation ||
          _isShuttingDown) {
        throw const AsyncError(
          code: AsyncErrorCode.workerTerminated,
          message: 'The worker generation is no longer available',
        );
      }
      if (!maintenance) _validateRequest(request);
      final descriptor =
          _describe(request, targetWorker, maintenance: maintenance);
      targetWorker.requests[request.requestId] = descriptor;
      if (!maintenance && request is CommitTransactionRequest) {
        _blockedTransactions.add(request.txnId);
      }
      if (!maintenance && request is RollbackTransactionRequest) {
        _blockedTransactions.add(request.txnId);
      }
      if (!maintenance && request is XaIdRequest) _blockedXa.add(request.xaId);
      completer = (targetWorker..recordQueueWait(queueWaitMicros)).send(
        request,
        maintenance: maintenance,
      );
      if (context != null) context.executionStage = null;
      _recordCancelAttempt(request, targetWorker);
      final effectiveTimeout = _requestTimeout ?? _defaultRequestTimeout;
      final response = effectiveTimeout == Duration.zero
          ? await completer.future
          : await completer.future.timeout(
              effectiveTimeout,
              onTimeout: () {
                targetWorker.removePending(request.requestId);
                targetWorker.abandoned[request.requestId] = descriptor;
                descriptor.timeout = QueryError(
                  message: 'The worker operation timed out',
                  details: OdbcErrorDetails(
                    code: OdbcErrorCode.timeout,
                    operation: request.type.name,
                    requestId: request.requestId,
                    workerId: targetWorker.index,
                    connectionId: descriptor.connectionId?.toString(),
                    outcomeUnknown: true,
                  ),
                );
                targetWorker.timeouts++;
                NativeCallContext.record(descriptor.timeout!);
                final error = AsyncError(
                  code: AsyncErrorCode.requestTimeout,
                  message:
                      'Worker ${targetWorker.index} did not respond within '
                      '${effectiveTimeout.inSeconds}s',
                );
                // Complete the underlying Completer with the same error so any
                // external listener resolves. The abandoned descriptor retains
                // late completion evidence separately from the returned Future.
                if (!completer!.isCompleted) {
                  completer.completeError(error);
                }
                throw error;
              },
            );
      if (targetWorker.closed ||
          targetWorker.generation != _generation ||
          _isShuttingDown) {
        throw const AsyncError(
          code: AsyncErrorCode.workerTerminated,
          message: 'The worker generation ended before delivery',
        );
      }
      final snapshot =
          targetWorker.failureSnapshots.remove(request.requestId) ??
              response.failure;
      if (context != null) {
        context
          ..executionStage =
              targetWorker.executionStages.remove(request.requestId) ??
                  snapshot?.executionStage
          ..receivedResponse = true;
        if (response is BoolResponse) {
          context.completionStatus =
              response.completionStatus ?? (response.value ? 0 : null);
        }
      }
      if (snapshot != null) {
        NativeCallContext.record(snapshot.toError(targetWorker.index));
      }
      if (request is CommitTransactionRequest ||
          request is RollbackTransactionRequest) {
        final id = descriptor.resourceId;
        final status = response is BoolResponse
            ? response.completionStatus ?? (response.value ? 0 : null)
            : null;
        if (status == 0 ||
            status == 1 ||
            status == 2 ||
            snapshot?.executionStage == NativeExecutionStage.notStarted) {
          _blockedTransactions.remove(id);
        }
        if (status == 1 && descriptor.connectionId != null) {
          _quarantinedConnections.add(descriptor.connectionId!);
        }
      } else if (request is XaIdRequest &&
          (snapshot?.executionStage == NativeExecutionStage.notStarted ||
              (response is IntResponse &&
                  !(snapshot?.outcomeUnknown ?? false)))) {
        _blockedXa.remove(request.xaId);
      }
      counted = true;
      if (!maintenance && (snapshot != null || _responseHasError(response))) {
        targetWorker.failedRequests++;
      } else if (!maintenance) {
        targetWorker.completedRequests++;
      }
      _recordCancelResponse(request, response, targetWorker);
      _recordAffinity(request, response, targetWorker);
      return response as T;
    } catch (_) {
      if (!maintenance && !counted) targetWorker.failedRequests++;
      rethrow;
    } finally {
      final elapsedMicros = stopwatch.elapsedMicroseconds;
      if (reservedSlot && !slotReleased && completer == null) {
        _releaseReservedBackpressureSlot();
      }
      targetWorker.requests.remove(request.requestId);
      if (!maintenance) {
        targetWorker
          ..recordLatency(elapsedMicros)
          ..recordExecution(elapsedMicros);
        if (!targetWorker.abandoned.containsKey(request.requestId) &&
            completer != null) {
          targetWorker.finishRequest();
        }
      }
      targetWorker.executionStages.remove(request.requestId);
      _drainBackpressureWaiters();
    }
  }

  void _failAllPending(AsyncError error) {
    for (final worker in _workers) {
      worker.failAll(error);
    }
    final waiters = List<_BackpressureWaiter>.from(_backpressureWaiters);
    _backpressureWaiters.clear();
    _backpressureSlotsReserved = 0;
    for (final waiter in waiters) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(error);
      }
    }
  }

  void _handleResponse(WorkerResponse response, _WorkerChannel worker) {
    final entry = worker.abandoned[response.requestId];
    if (entry != null) {
      if (entry.responded) return;
      entry.responded = true;
      worker.maintenance = worker.maintenance
          .then((_) => _reconcileLate(worker, entry, response))
          .catchError((Object error, StackTrace stack) {
        _diagnose(
          translateOdbcError(
            error,
            operation: 'reconcileLate',
            stackTrace: stack,
          ),
        );
      });
      return;
    }
    if (worker.pendingRequests.containsKey(response.requestId)) {
      worker.complete(response);
    } else {
      worker.failureSnapshots.remove(response.requestId);
      worker.executionStages.remove(response.requestId);
    }
  }

  FutureOr<bool> _acquireBackpressureSlot(WorkerRequest request) {
    final limit = maxPendingRequests;
    if (limit == null) return false;

    if (backpressureMode == AsyncBackpressureMode.failFast) {
      final pending = _pendingOrReservedRequests;
      if (pending >= limit) {
        throw _resourceExhausted(request, pending, limit);
      }
      _backpressureSlotsReserved++;
      return true;
    }

    if (_pendingOrReservedRequests < limit && _backpressureWaiters.isEmpty) {
      _backpressureSlotsReserved++;
      return true;
    }

    final waiter = _BackpressureWaiter();
    _backpressureWaiters.addLast(waiter);
    _drainBackpressureWaiters();

    final timeout =
        backpressureTimeout ?? _requestTimeout ?? _defaultRequestTimeout;
    final future = timeout == Duration.zero
        ? waiter.completer.future
        : waiter.completer.future.timeout(
            timeout,
            onTimeout: () {
              _backpressureWaiters.remove(waiter);
              throw _resourceExhausted(
                request,
                _pendingOrReservedRequests,
                limit,
              );
            },
          );
    return future.then((_) => true);
  }

  int get _pendingOrReservedRequests {
    return _workers.fold<int>(
          0,
          (total, worker) =>
              total +
              worker.pendingRequests.keys
                  .where((id) => !(worker.requests[id]?.maintenance ?? false))
                  .length +
              worker.abandoned.values
                  .where((entry) => !entry.maintenance)
                  .length,
        ) +
        _backpressureSlotsReserved;
  }

  AsyncError _resourceExhausted(
    WorkerRequest request,
    int pending,
    int limit,
  ) {
    return AsyncError(
      code: AsyncErrorCode.resourceExhausted,
      message: 'Async worker pool queue is full '
          '($pending/$limit pending requests); request '
          '${request.runtimeType} was not routed',
    );
  }

  void _releaseReservedBackpressureSlot() {
    if (_backpressureSlotsReserved > 0) {
      _backpressureSlotsReserved--;
    }
  }

  void _drainBackpressureWaiters() {
    final limit = maxPendingRequests;
    if (limit == null) return;

    while (
        _backpressureWaiters.isNotEmpty && _pendingOrReservedRequests < limit) {
      final waiter = _backpressureWaiters.removeFirst();
      if (waiter.completer.isCompleted) continue;
      _backpressureSlotsReserved++;
      waiter.completer.complete();
    }
  }

  void _recordFallbackToBlocking(int connectionId) {
    _workerForConnection(connectionId).fallbacksToBlocking++;
  }

  bool _responseHasError(WorkerResponse response) {
    if (response.failure != null) return true;
    return switch (response) {
      ConnectResponse(:final error) => error != null && error.isNotEmpty,
      QueryResponse(:final error) => error != null && error.isNotEmpty,
      PoolStateResponse(:final error) => error != null && error.isNotEmpty,
      MetricsResponse(:final error) => error != null && error.isNotEmpty,
      CacheMetricsResponse(:final error) => error != null && error.isNotEmpty,
      ClearCacheResponse(:final error) => error != null && error.isNotEmpty,
      StructuredErrorResponse(:final error) =>
        error != null && error.isNotEmpty,
      AuditPayloadResponse(:final error) => error != null && error.isNotEmpty,
      StreamFetchResponse(:final success, :final error) =>
        !success || (error != null && error.isNotEmpty),
      BoolResponse(:final value) => !value,
      InitializeResponse(:final success) => !success,
      IntResponse(:final value) => value < 0,
      _ => false,
    };
  }

  void _recordCancelAttempt(WorkerRequest request, _WorkerChannel worker) {
    if (_isCancelRequest(request)) {
      worker.cancelAttempts++;
    }
  }

  void _recordCancelResponse(
    WorkerRequest request,
    WorkerResponse response,
    _WorkerChannel worker,
  ) {
    if (!_isCancelRequest(request)) return;

    if (response is BoolResponse && response.value) {
      worker.cancelSucceeded++;
    } else if (response is BoolResponse && !response.value) {
      worker.cancelUnsupported++;
    }
  }

  bool _isCancelRequest(WorkerRequest request) {
    return request is AsyncCancelRequest ||
        request is StreamCancelRequest ||
        request is CancelStatementRequest;
  }

  int _nextRequestId() => _requestIdCounter++;

  _WorkerChannel _leastLoadedWorker() {
    final ready = _workers.where((worker) => worker.isReady);
    if (ready.isEmpty) {
      throw const AsyncError(
        code: AsyncErrorCode.workerTerminated,
        message: 'No worker is available',
      );
    }
    return ready.reduce((a, b) {
      final activeComparison = a.activeRequests.compareTo(b.activeRequests);
      if (activeComparison < 0) return a;
      if (activeComparison > 0) return b;

      final routedComparison = a.totalRouted.compareTo(b.totalRouted);
      if (routedComparison < 0) return a;
      if (routedComparison > 0) return b;

      return a.index <= b.index ? a : b;
    });
  }

  _WorkerChannel? _workerByIndex(int? index) {
    if (index == null || index < 0 || index >= _workers.length) {
      return null;
    }
    return _workers[index];
  }

  _WorkerChannel _workerForConnection(int connectionId) {
    return _workerByIndex(_connectionWorkerById[connectionId]) ??
        _leastLoadedWorker();
  }

  _WorkerChannel _workerForStatement(int stmtId) {
    return _workerByIndex(_statementWorkerById[stmtId]) ?? _leastLoadedWorker();
  }

  _WorkerChannel _workerForTransaction(int txnId) {
    return _workerByIndex(_transactionWorkerById[txnId]) ??
        _leastLoadedWorker();
  }

  _WorkerChannel _workerForXa(int xaId) {
    return _workerByIndex(_xaWorkerById[xaId]) ?? _leastLoadedWorker();
  }

  _WorkerChannel _workerForStream(int streamId) {
    return _workerByIndex(_streamWorkerById[streamId]) ?? _leastLoadedWorker();
  }

  _WorkerChannel _workerForAsyncRequest(int asyncRequestId) {
    return _workerByIndex(_asyncRequestWorkerById[asyncRequestId]) ??
        _leastLoadedWorker();
  }

  bool _canRerouteAfterBackpressure(WorkerRequest request) {
    return switch (request) {
      ConnectRequest() ||
      ValidateConnectionStringRequest() ||
      DetectDriverRequest() ||
      GetDriverCapabilitiesRequest() ||
      GetVersionRequest() ||
      GetMetricsRequest() ||
      GetCacheMetricsRequest() ||
      ClearCacheRequest() ||
      ClearAllStatementsRequest() ||
      SetLogLevelRequest() ||
      AuditEnableRequest() ||
      AuditGetEventsRequest() ||
      AuditGetStatusRequest() ||
      AuditClearRequest() ||
      MetadataCacheEnableRequest() ||
      MetadataCacheStatsRequest() ||
      MetadataCacheClearRequest() ||
      PoolCreateRequest() ||
      PoolGetConnectionRequest() ||
      PoolHealthCheckRequest() ||
      PoolGetStateRequest() ||
      PoolGetStateJsonRequest() ||
      PoolSetSizeRequest() ||
      PoolCloseRequest() ||
      BulkInsertParallelRequest() ||
      CancelStatementRequest() ||
      StreamCancelRequest() ||
      AsyncCancelRequest() ||
      GetErrorRequest() ||
      GetStructuredErrorRequest() =>
        true,
      _ => false,
    };
  }

  _WorkerChannel _resolveWorker(WorkerRequest request) {
    return switch (request) {
      ConnectRequest() ||
      ValidateConnectionStringRequest() ||
      DetectDriverRequest() ||
      GetDriverCapabilitiesRequest() ||
      GetVersionRequest() ||
      GetMetricsRequest() ||
      GetCacheMetricsRequest() ||
      ClearCacheRequest() ||
      ClearAllStatementsRequest() ||
      SetLogLevelRequest() ||
      AuditEnableRequest() ||
      AuditGetEventsRequest() ||
      AuditGetStatusRequest() ||
      AuditClearRequest() ||
      MetadataCacheEnableRequest() ||
      MetadataCacheStatsRequest() ||
      MetadataCacheClearRequest() ||
      PoolCreateRequest() ||
      PoolGetConnectionRequest() ||
      PoolHealthCheckRequest() ||
      PoolGetStateRequest() ||
      PoolGetStateJsonRequest() ||
      PoolSetSizeRequest() ||
      PoolCloseRequest() ||
      BulkInsertParallelRequest() =>
        _leastLoadedWorker(),
      DisconnectRequest(:final connectionId) ||
      GetConnectionDbmsInfoRequest(:final connectionId) ||
      GetStructuredErrorForConnectionRequest(:final connectionId) ||
      ExecuteQueryParamsRequest(:final connectionId) ||
      ExecuteQueryMultiRequest(:final connectionId) ||
      ExecuteQueryMultiParamsRequest(:final connectionId) ||
      BeginTransactionRequest(:final connectionId) ||
      XaStartRequest(:final connectionId) ||
      XaRecoverRequest(:final connectionId) ||
      XaResumePreparedRequest(:final connectionId) ||
      PrepareRequest(:final connectionId) ||
      CatalogTablesRequest(:final connectionId) ||
      CatalogColumnsRequest(:final connectionId) ||
      CatalogTypeInfoRequest(:final connectionId) ||
      CatalogPrimaryKeysRequest(:final connectionId) ||
      CatalogForeignKeysRequest(:final connectionId) ||
      CatalogIndexesRequest(:final connectionId) ||
      BulkInsertArrayRequest(:final connectionId) =>
        _workerForConnection(connectionId),
      ExecutePreparedRequest(:final stmtId) ||
      CloseStatementRequest(:final stmtId) =>
        _workerForStatement(stmtId),
      // Cancel must reach the worker that owns the prepared statement: each
      // worker has its own NativeOdbcConnection and stmtId is local to it.
      // Routing to _leastLoadedWorker() silently fails on multi-worker pools.
      CancelStatementRequest(:final stmtId) => _workerForStatement(stmtId),
      CommitTransactionRequest(:final txnId) ||
      RollbackTransactionRequest(:final txnId) ||
      SavepointCreateRequest(:final txnId) ||
      SavepointRollbackRequest(:final txnId) ||
      SavepointReleaseRequest(:final txnId) =>
        _workerForTransaction(txnId),
      XaIdRequest(:final xaId) => _workerForXa(xaId),
      StreamStartRequest(:final connectionId) ||
      StreamStartBatchedRequest(:final connectionId) ||
      StreamStartAsyncRequest(:final connectionId) ||
      StreamMultiStartBatchedRequest(:final connectionId) ||
      StreamMultiStartAsyncRequest(:final connectionId) ||
      ExecuteAsyncStartRequest(:final connectionId) ||
      ExecuteAsyncStartParamsRequest(:final connectionId) =>
        _workerForConnection(connectionId),
      StreamFetchRequest(:final streamId) ||
      StreamCloseRequest(:final streamId) ||
      StreamPollAsyncRequest(:final streamId) ||
      StreamPollFetchRequest(:final streamId) =>
        _workerForStream(streamId),
      StreamCancelRequest() => _leastLoadedWorker(),
      AsyncPollRequest(:final asyncRequestId) ||
      AsyncGetResultRequest(:final asyncRequestId) ||
      AsyncFreeRequest(:final asyncRequestId) =>
        _workerForAsyncRequest(asyncRequestId),
      AsyncCancelRequest() => _leastLoadedWorker(),
      PoolReleaseConnectionRequest(:final connectionId) =>
        _workerForConnection(connectionId),
      GetErrorRequest() || GetStructuredErrorRequest() => _leastLoadedWorker(),
      InitializeRequest() => _leastLoadedWorker(),
    };
  }

  void _recordAffinity(
    WorkerRequest request,
    WorkerResponse response,
    _WorkerChannel worker,
  ) {
    switch ((request, response)) {
      case (ConnectRequest(), ConnectResponse(:final connectionId))
          when connectionId > 0:
        _connectionWorkerById[connectionId] = worker.index;
        _nativeConnectionLifetimes[connectionId] = Object();
        _deadConnections.remove(connectionId);
      case (
            PoolGetConnectionRequest(:final poolId),
            IntResponse(value: final connectionId)
          )
          when connectionId > 0:
        _connectionWorkerById[connectionId] = worker.index;
        _nativeConnectionLifetimes[connectionId] = Object();
        _connectionPoolById[connectionId] = poolId;
        _deadConnections.remove(connectionId);
      case (PoolCloseRequest(:final poolId), BoolResponse(value: true)):
        _connectionPoolById.entries
            .where((entry) => entry.value == poolId)
            .map((entry) => entry.key)
            .toList(growable: false)
            .forEach(_clearConnectionAffinity);
      case (DisconnectRequest(:final connectionId), BoolResponse(:final value))
          when value:
      case (
            PoolReleaseConnectionRequest(:final connectionId),
            BoolResponse(:final value),
          )
          when value:
        _clearConnectionAffinity(connectionId);
      case (PrepareRequest(:final connectionId), IntResponse(value: final id))
          when id > 0:
        _statementWorkerById[id] = worker.index;
        _statementConnectionById[id] = connectionId;
      case (CloseStatementRequest(:final stmtId), BoolResponse(:final value))
          when value:
        _statementWorkerById.remove(stmtId);
        _statementConnectionById.remove(stmtId);
      case (ClearAllStatementsRequest(), IntResponse(value: 0)):
        _statementWorkerById.clear();
        _statementConnectionById.clear();
      case (
            BeginTransactionRequest(:final connectionId),
            IntResponse(value: final id),
          )
          when id > 0:
        _transactionWorkerById[id] = worker.index;
        _transactionConnectionById[id] = connectionId;
      case (
            CommitTransactionRequest(:final txnId),
            BoolResponse(:final completionStatus, :final value)
          )
          when completionStatus == 0 ||
              completionStatus == 1 ||
              (completionStatus == null && value):
      case (
            RollbackTransactionRequest(:final txnId),
            BoolResponse(:final completionStatus, :final value)
          )
          when completionStatus == 0 ||
              completionStatus == 1 ||
              (completionStatus == null && value):
        _blockedTransactions.remove(txnId);
        _transactionWorkerById.remove(txnId);
        _transactionConnectionById.remove(txnId);
      case (XaStartRequest(:final connectionId), IntResponse(value: final id))
          when id > 0:
      case (
            XaResumePreparedRequest(:final connectionId),
            IntResponse(value: final id),
          )
          when id > 0:
        _xaWorkerById[id] = worker.index;
        _xaConnectionById[id] = connectionId;
      case (XaIdRequest(:final xaId), IntResponse(value: final rc))
          when rc == 0 &&
              (request.type == RequestType.xaCommitPrepared ||
                  request.type == RequestType.xaRollbackPrepared ||
                  request.type == RequestType.xaCommitOnePhase ||
                  request.type == RequestType.xaRollbackActive):
        _blockedXa.remove(xaId);
        _xaWorkerById.remove(xaId);
        _xaConnectionById.remove(xaId);
      case (
            StreamStartRequest(:final connectionId),
            IntResponse(value: final id)
          )
          when id > 0:
      case (
            StreamStartBatchedRequest(:final connectionId),
            IntResponse(value: final id)
          )
          when id > 0:
      case (
            StreamStartAsyncRequest(:final connectionId),
            IntResponse(value: final id)
          )
          when id > 0:
      case (
            StreamMultiStartBatchedRequest(:final connectionId),
            IntResponse(value: final id)
          )
          when id > 0:
      case (
            StreamMultiStartAsyncRequest(:final connectionId),
            IntResponse(value: final id)
          )
          when id > 0:
        _streamWorkerById[id] = worker.index;
        _streamConnectionById[id] = connectionId;
      case (StreamCloseRequest(:final streamId), BoolResponse(:final value))
          when value:
        _streamWorkerById.remove(streamId);
        _streamConnectionById.remove(streamId);
      case (
            ExecuteAsyncStartRequest(:final connectionId),
            IntResponse(value: final id)
          )
          when id > 0:
      case (
            ExecuteAsyncStartParamsRequest(:final connectionId),
            IntResponse(value: final id)
          )
          when id > 0:
        _asyncRequestWorkerById[id] = worker.index;
        _asyncRequestConnectionById[id] = connectionId;
      case (AsyncFreeRequest(:final asyncRequestId), BoolResponse(:final value))
          when value:
        _asyncRequestWorkerById.remove(asyncRequestId);
        _asyncRequestConnectionById.remove(asyncRequestId);
      default:
        break;
    }
  }

  void _clearConnectionAffinity(int connectionId) {
    _nativeConnectionLifetimes.remove(connectionId);
    _quarantinedConnections.remove(connectionId);
    _resumedXa
        .removeWhere((key, _) => key.startsWith('$_generation:$connectionId:'));
    _pendingXaResume
        .removeWhere((key) => key.startsWith('$_generation:$connectionId:'));
    _connectionWorkerById.remove(connectionId);
    _connectionPoolById.remove(connectionId);
    for (final entry in [
      (_streamConnectionById, _streamWorkerById),
      (_asyncRequestConnectionById, _asyncRequestWorkerById),
    ]) {
      final ids = entry.$1.entries
          .where((e) => e.value == connectionId)
          .map((e) => e.key)
          .toList(growable: false);
      for (final id in ids) {
        entry.$1.remove(id);
        entry.$2.remove(id);
      }
    }
    final stmtIds = _statementConnectionById.entries
        .where((entry) => entry.value == connectionId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final stmtId in stmtIds) {
      _statementWorkerById.remove(stmtId);
      _statementConnectionById.remove(stmtId);
      _namedParamOrderByStmtId.remove(stmtId);
    }
    // Clean up transaction affinity for transactions that belonged to this
    // connection (native rolls them back on disconnect; Dart must not retain
    // stale worker mappings).
    final txnIds = _transactionConnectionById.entries
        .where((entry) => entry.value == connectionId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final txnId in txnIds) {
      _blockedTransactions.remove(txnId);
      _transactionWorkerById.remove(txnId);
      _transactionConnectionById.remove(txnId);
    }
    final xaIds = _xaConnectionById.entries
        .where((entry) => entry.value == connectionId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final xaId in xaIds) {
      _blockedXa.remove(xaId);
      _xaWorkerById.remove(xaId);
      _xaConnectionById.remove(xaId);
    }
  }

  void _clearWorkerAffinity(int workerIndex) {
    _connectionWorkerById.entries
        .where((entry) => entry.value == workerIndex)
        .map((entry) => entry.key)
        .toList(growable: false)
        .forEach(_clearConnectionAffinity);

    _statementWorkerById.removeWhere((_, value) => value == workerIndex);
    final txnIdsForWorker = _transactionWorkerById.entries
        .where((e) => e.value == workerIndex)
        .map((e) => e.key)
        .toList(growable: false);
    for (final txnId in txnIdsForWorker) {
      _blockedTransactions.remove(txnId);
      _transactionWorkerById.remove(txnId);
      _transactionConnectionById.remove(txnId);
    }
    final xaIdsForWorker = _xaWorkerById.entries
        .where((e) => e.value == workerIndex)
        .map((e) => e.key)
        .toList(growable: false);
    for (final xaId in xaIdsForWorker) {
      _blockedXa.remove(xaId);
      _xaWorkerById.remove(xaId);
      _xaConnectionById.remove(xaId);
    }
    _streamWorkerById.removeWhere((_, value) => value == workerIndex);
    _asyncRequestWorkerById.removeWhere((_, value) => value == workerIndex);
    _streamConnectionById
        .removeWhere((id, _) => !_streamWorkerById.containsKey(id));
    _asyncRequestConnectionById
        .removeWhere((id, _) => !_asyncRequestWorkerById.containsKey(id));
  }
}

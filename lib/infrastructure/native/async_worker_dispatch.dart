part of 'async_native_odbc_connection.dart';

mixin _AsyncWorkerDispatch on _AsyncOdbcState {
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
  }) async {
    final queueStopwatch = Stopwatch()..start();
    final acquiredSlot = _acquireBackpressureSlot(request);
    final bool waitedForSlot;
    final bool reservedSlot;
    if (acquiredSlot is Future<bool>) {
      waitedForSlot = true;
      reservedSlot = await acquiredSlot;
    } else {
      waitedForSlot = false;
      reservedSlot = acquiredSlot;
    }
    final queueWaitMicros = (queueStopwatch..stop()).elapsedMicroseconds;
    final targetWorker = waitedForSlot && rerouteAfterBackpressure
        ? _resolveWorker(request)
        : worker;
    final stopwatch = Stopwatch()..start();
    final executionStopwatch = Stopwatch()..start();
    Completer<WorkerResponse>? completer;
    var slotReleased = false;
    try {
      if (reservedSlot) {
        _releaseReservedBackpressureSlot();
        slotReleased = true;
      }
      completer = (targetWorker..recordQueueWait(queueWaitMicros)).send(
        request,
      );
      _recordCancelAttempt(request, targetWorker);
      final effectiveTimeout = _requestTimeout ?? _defaultRequestTimeout;
      final response = effectiveTimeout == Duration.zero
          ? await completer.future
          : await completer.future.timeout(
              effectiveTimeout,
              onTimeout: () {
                targetWorker.removePending(request.requestId);
                targetWorker.timeouts++;
                final error = AsyncError(
                  code: AsyncErrorCode.requestTimeout,
                  message:
                      'Worker ${targetWorker.index} did not respond within '
                      '${effectiveTimeout.inSeconds}s',
                );
                // Complete the underlying Completer with the same error so any
                // external listener on completer.future also resolves rather
                // than dangling. Late worker responses are a no-op because the
                // pendingRequests entry is already removed.
                if (!completer!.isCompleted) {
                  completer.completeError(error);
                }
                throw error;
              },
            );
      if (_responseHasError(response)) {
        targetWorker.failedRequests++;
      } else {
        targetWorker.completedRequests++;
      }
      _recordCancelResponse(request, response, targetWorker);
      _recordAffinity(request, response, targetWorker);
      return response as T;
    } catch (_) {
      targetWorker.failedRequests++;
      rethrow;
    } finally {
      executionStopwatch.stop();
      if (reservedSlot && !slotReleased && completer == null) {
        _releaseReservedBackpressureSlot();
      }
      targetWorker
        ..recordLatency(stopwatch.elapsedMicroseconds)
        ..recordExecution(executionStopwatch.elapsedMicroseconds)
        ..finishRequest();
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
    worker.complete(response);
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
          (total, worker) => total + worker.pendingRequests.length,
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
    return _workers.reduce((a, b) {
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
      case (
            PoolGetConnectionRequest(),
            IntResponse(value: final connectionId),
          )
          when connectionId > 0:
        _connectionWorkerById[connectionId] = worker.index;
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
      case (CommitTransactionRequest(:final txnId), BoolResponse()):
      case (RollbackTransactionRequest(:final txnId), BoolResponse()):
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
        _xaWorkerById.remove(xaId);
        _xaConnectionById.remove(xaId);
      case (StreamStartRequest(), IntResponse(value: final id)) when id > 0:
      case (StreamStartBatchedRequest(), IntResponse(value: final id))
          when id > 0:
      case (StreamStartAsyncRequest(), IntResponse(value: final id))
          when id > 0:
      case (StreamMultiStartBatchedRequest(), IntResponse(value: final id))
          when id > 0:
      case (StreamMultiStartAsyncRequest(), IntResponse(value: final id))
          when id > 0:
        _streamWorkerById[id] = worker.index;
      case (StreamCloseRequest(:final streamId), BoolResponse(:final value))
          when value:
        _streamWorkerById.remove(streamId);
      case (ExecuteAsyncStartRequest(), IntResponse(value: final id))
          when id > 0:
      case (ExecuteAsyncStartParamsRequest(), IntResponse(value: final id))
          when id > 0:
        _asyncRequestWorkerById[id] = worker.index;
      case (AsyncFreeRequest(:final asyncRequestId), BoolResponse(:final value))
          when value:
        _asyncRequestWorkerById.remove(asyncRequestId);
      default:
        break;
    }
  }

  void _clearConnectionAffinity(int connectionId) {
    _connectionWorkerById.remove(connectionId);
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
      _transactionWorkerById.remove(txnId);
      _transactionConnectionById.remove(txnId);
    }
    final xaIds = _xaConnectionById.entries
        .where((entry) => entry.value == connectionId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final xaId in xaIds) {
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
      _transactionWorkerById.remove(txnId);
      _transactionConnectionById.remove(txnId);
    }
    final xaIdsForWorker = _xaWorkerById.entries
        .where((e) => e.value == workerIndex)
        .map((e) => e.key)
        .toList(growable: false);
    for (final xaId in xaIdsForWorker) {
      _xaWorkerById.remove(xaId);
      _xaConnectionById.remove(xaId);
    }
    _streamWorkerById.removeWhere((_, value) => value == workerIndex);
    _asyncRequestWorkerById.removeWhere((_, value) => value == workerIndex);
  }
}

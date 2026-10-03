part of 'async_native_odbc_connection.dart';

mixin _AsyncWorkerLifecycle
    on
        _AsyncOdbcState,
        _AsyncWorkerDispatch,
        _AsyncConnection,
        _AsyncWorkerReconciliation {
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
  Future<bool> initialize() {
    if (_isInitialized) return Future.value(true);
    final existing = _initialization;
    if (existing != null) {
      return _observeInitialization(existing, _initializationContext!);
    }
    _isShuttingDown = false;
    final generation = _generation;
    late NativeCallContext context;
    final future = NativeCallContext.capture(() {
      context = NativeCallContext.current!;
      return _initializeGeneration(generation);
    });
    _initialization = future;
    _initializationContext = context;
    return _observeInitialization(future, context);
  }

  Future<bool> _observeInitialization(
    Future<bool> attempt,
    NativeCallContext context,
  ) async {
    final success = await attempt;
    if (!success && context.failure != null) {
      NativeCallContext.record(context.failure!);
    }
    return success;
  }

  void _checkGeneration(int generation) {
    if (_generation != generation || _isShuttingDown) {
      throw const AsyncError(
        code: AsyncErrorCode.workerTerminated,
        message: 'Worker initialization was interrupted',
      );
    }
  }

  Future<bool> _initializeGeneration(int generation) async {
    final workers = <_WorkerChannel>[];
    try {
      for (var i = 0; i < workerCount; i++) {
        workers.add(await _spawnWorker(i, generation));
        _checkGeneration(generation);
      }
      for (final worker in workers) {
        _checkGeneration(generation);
        if (worker.startupFailure case final failure?) {
          NativeCallContext.record(failure);
          return false;
        }
        final response = await _sendRequestOnWorker<InitializeResponse>(
          worker,
          InitializeRequest(_nextRequestId()),
        );
        _checkGeneration(generation);
        if (!response.success) return false;
      }
      _workers.addAll(workers);
      _initializingWorkers.removeAll(workers);
      _isInitialized = true;
      return true;
    } on Object {
      if (_generation == generation && !_isShuttingDown) {
        for (final worker in {...workers, ..._initializingWorkers}) {
          if (worker.generation == generation &&
              worker.startupFailure != null) {
            NativeCallContext.record(worker.startupFailure!);
            return false;
          }
        }
      }
      rethrow;
    } finally {
      if (!_isInitialized || _generation != generation) {
        for (final worker in _initializingWorkers
            .where((w) => w.generation == generation)
            .toList()) {
          worker
            ..failAll(
              const AsyncError(
                code: AsyncErrorCode.workerTerminated,
                message: 'Worker initialization failed',
              ),
            )
            ..dispose();
          _initializingWorkers.remove(worker);
        }
      }
      if (_generation == generation) _initialization = null;
    }
  }

  Future<_WorkerChannel> _spawnWorker(int index, int generation) async {
    final worker = _WorkerChannel(
      index: index,
      generation: generation,
      receivePort: ReceivePort(),
    );
    _initializingWorkers.add(worker);
    void terminated([Object? error, StackTrace? stack]) {
      if (worker.closed || generation != _generation) return;
      const failure = AsyncError(
        code: AsyncErrorCode.workerTerminated,
        message: 'Worker isolate terminated',
      );
      if (!worker.handshake.isCompleted) {
        worker.handshake.completeError(failure);
      }
      worker.failAll(failure);
      _abandonWorker(worker, failure);
      worker.dispose();
      _clearWorkerAffinity(worker.index);
      _drainBackpressureWaiters();
      if (_isInitialized && !_isShuttingDown) {
        unawaited(
          _triggerAutoRecovery(
            reason: 'Worker isolate terminated',
            error: error,
            stackTrace: stack,
          ).catchError((Object e, StackTrace st) {
            _diagnose(
              translateOdbcError(
                e,
                operation: 'recoverWorker',
                stackTrace: st,
              ),
            );
          }),
        );
      }
    }

    worker.exitPort.listen((_) => terminated());
    worker.errorPort.listen((message) {
      final parts = message is List ? message : null;
      terminated(
        parts?.first,
        parts != null && parts.length > 1
            ? StackTrace.fromString(parts[1].toString())
            : null,
      );
    });
    worker.receivePort.listen((message) {
      if (worker.closed || generation != _generation) return;
      if (message is SendPort) {
        if (!worker.handshake.isCompleted) worker.handshake.complete(message);
      } else if (message is WorkerReply) {
        final id = message.response.requestId;
        if (!worker.pendingRequests.containsKey(id) &&
            (worker.abandoned[id] == null || worker.abandoned[id]!.responded)) {
          return;
        }
        if (message.failure != null) {
          worker.failureSnapshots[id] = message.failure!;
        }
        worker.executionStages[id] = message.executionStage;
        _handleResponse(message.response, worker);
      } else if (message is InitializeResponse &&
          message.requestId == 0 &&
          message.failure != null) {
        worker.startupFailure = message.failure!.toError(worker.index);
        NativeCallContext.record(worker.startupFailure!);
        for (final entry in worker.requests.values.toList()) {
          if (entry.type == RequestType.initialize &&
              worker.pendingRequests.containsKey(entry.requestId)) {
            _handleResponse(
              InitializeResponse(
                entry.requestId,
                success: false,
                failure: message.failure,
              ),
              worker,
            );
          }
        }
      } else if (message is WorkerResponse) {
        _handleResponse(message, worker);
      } else if (message == _workerTerminatedSignal) {
        terminated();
      }
    });
    final spawning = Isolate.spawn(
      _isolateEntry ?? workerEntry,
      worker.receivePort.sendPort,
      onExit: worker.exitPort.sendPort,
      onError: worker.errorPort.sendPort,
    ).then((isolate) {
      worker.isolate = isolate;
      if (worker.closed || generation != _generation) isolate.kill();
      return isolate;
    });
    final timeout = _requestTimeout ?? _defaultRequestTimeout;
    final timer = timeout == Duration.zero
        ? null
        : Timer(timeout, () {
            if (!worker.handshake.isCompleted) {
              worker.handshake.completeError(
                const AsyncError(
                  code: AsyncErrorCode.requestTimeout,
                  message: 'Worker handshake timed out',
                ),
              );
            }
          });
    try {
      final values = await Future.wait<Object>(
        [spawning, worker.handshake.future],
        eagerError: true,
      );
      _checkGeneration(generation);
      worker.sendPort = values[1] as SendPort;
      return worker;
    } finally {
      timer?.cancel();
    }
  }

  Future<String?> _safeGetWorkerError() async {
    final context = NativeCallContext.current;
    if (context?.failure != null) return context!.failure!.message;
    if (context?.receivedResponse ?? false) return null;
    try {
      final r = await _sendRequest<GetErrorResponse>(
        GetErrorRequest(_nextRequestId()),
      );
      final message = r.message;
      final trimmed = message.trim();
      if (trimmed.isEmpty || trimmed == 'No error') {
        return null;
      }
      return trimmed;
    } on Object catch (error, stack) {
      final failure = QueryError(
        message: 'The native operation failed',
        details: OdbcErrorDetails(
          secondaryErrors: [
            translateOdbcError(
              error,
              operation: 'collectDiagnostic',
              stackTrace: stack,
            ),
          ],
        ),
      );
      NativeCallContext.record(failure);
      return null;
    }
  }

  Future<void> _runSingleRecovery(Future<void> Function() operation) async {
    final inFlight = _recoveryInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final recovery = operation();
    _recoveryInFlight = recovery;

    try {
      await recovery;
    } finally {
      if (identical(_recoveryInFlight, recovery)) {
        _recoveryInFlight = null;
      }
    }
  }

  Future<void> _triggerAutoRecovery({
    required String reason,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    if (!autoRecoverOnWorkerCrash || _isShuttingDown) {
      return;
    }

    await _runSingleRecovery(() async {
      if (error != null) {
        AppLogger.severe(reason, error, stackTrace);
      } else {
        AppLogger.severe(reason);
      }
      await _recoverWorkerInternal();
    });
  }

  Future<void> _recoverWorkerInternal() async {
    dispose();
    if (!await initialize()) return;
    final cb = onWorkerRecovered;
    if (cb != null) {
      try {
        cb();
      } on Object catch (e, st) {
        AppLogger.warning(
          'onWorkerRecovered callback threw; ignored to keep recovery alive',
          e,
          st,
        );
      }
    }
  }

  /// Disposes the current worker and re-initializes a fresh one.
  ///
  /// All previous connection IDs are invalid after this. Callers must
  /// reconnect. Use when [autoRecoverOnWorkerCrash] is true and the worker
  /// has crashed.
  Future<void> recoverWorker() async {
    await _runSingleRecovery(_recoverWorkerInternal);
  }

  /// Shuts down worker isolates and invalidates Dart resource state.
  /// Native cancellation or cleanup cannot be confirmed for blocked calls.
  ///
  /// Completes any pending requests with error before shutting down. Sends
  /// shutdown to the worker, kills the isolate, and closes the receive port.
  /// Call when the async connection is no longer needed. After `dispose`,
  /// `isInitialized` is false and `initialize` can be called again. In-flight
  /// requests will complete with [AsyncError] (workerTerminated).
  void dispose() {
    _isShuttingDown = true;
    _generation++;
    _initialization = null;
    _initializationContext = null;
    _failAllPending(
      const AsyncError(
        code: AsyncErrorCode.workerTerminated,
        message: 'Connection disposed; worker shutting down',
      ),
    );
    _isInitialized = false;
    for (final worker in {..._workers, ..._initializingWorkers}) {
      _abandonWorker(
        worker,
        const AsyncError(
          code: AsyncErrorCode.workerTerminated,
          message: 'Connection disposed; cleanup is not confirmed',
        ),
      );
      worker
        ..failAll(
          const AsyncError(
            code: AsyncErrorCode.workerTerminated,
            message: 'Connection disposed',
          ),
        )
        ..dispose();
    }
    _initializingWorkers.clear();
    _blockedTransactions.clear();
    _blockedXa.clear();
    _quarantinedConnections.clear();
    _deadConnections.clear();
    _resumedXa.clear();
    _pendingXaResume.clear();
    _workers.clear();
    _namedParamOrderByStmtId.clear();
    _connectionWorkerById.clear();
    _nativeConnectionLifetimes.clear();
    _connectionPoolById.clear();
    _streamConnectionById.clear();
    _asyncRequestConnectionById.clear();
    _statementWorkerById.clear();
    _statementConnectionById.clear();
    _transactionWorkerById.clear();
    _transactionConnectionById.clear();
    _xaWorkerById.clear();
    _xaConnectionById.clear();
    _streamWorkerById.clear();
    _asyncRequestWorkerById.clear();
  }
}

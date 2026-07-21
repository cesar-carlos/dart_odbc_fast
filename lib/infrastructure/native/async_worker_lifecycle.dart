part of 'async_native_odbc_connection.dart';

mixin _AsyncWorkerLifecycle
    on _AsyncOdbcState, _AsyncWorkerDispatch, _AsyncConnection {
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
  Future<bool> initialize() async {
    if (_isInitialized) return true;
    _isShuttingDown = false;

    _workers.clear();
    for (var i = 0; i < workerCount; i++) {
      _workers.add(await _spawnWorker(i));
    }

    var initialized = true;
    for (final worker in _workers) {
      final initResp = await _sendRequestOnWorker<InitializeResponse>(
        worker,
        InitializeRequest(_nextRequestId()),
      );
      initialized = initialized && initResp.success;
    }
    _isInitialized = initialized;
    return initialized;
  }

  Future<_WorkerChannel> _spawnWorker(int index) async {
    final handshake = Completer<SendPort>();
    final receivePort = ReceivePort();
    final worker = _WorkerChannel(index: index, receivePort: receivePort);

    receivePort.listen(
      (message) {
        if (message is SendPort) {
          if (!handshake.isCompleted) handshake.complete(message);
        } else if (message is WorkerResponse) {
          _handleResponse(message, worker);
        } else if (message == _workerTerminatedSignal) {
          worker.failAll(
            const AsyncError(
              code: AsyncErrorCode.workerTerminated,
              message: 'Worker isolate terminated',
            ),
          );
          _clearWorkerAffinity(worker.index);
          _drainBackpressureWaiters();
        }
      },
      onError: (Object error, StackTrace stackTrace) async {
        worker.failAll(
          AsyncError(
            code: AsyncErrorCode.workerTerminated,
            message: 'Worker isolate ${worker.index} error: $error',
          ),
        );
        _clearWorkerAffinity(worker.index);
        await _triggerAutoRecovery(
          reason: 'Worker isolate ${worker.index} crashed',
          error: error,
          stackTrace: stackTrace,
        );
      },
      onDone: () async {
        if (worker.pendingRequests.isNotEmpty) {
          worker.failAll(
            const AsyncError(
              code: AsyncErrorCode.workerTerminated,
              message: 'Worker isolate terminated',
            ),
          );
        }
        _clearWorkerAffinity(worker.index);
        await _triggerAutoRecovery(reason: 'Worker isolate terminated');
      },
    );

    worker
      ..isolate = await Isolate.spawn(
        _isolateEntry ?? workerEntry,
        receivePort.sendPort,
      )
      ..sendPort = await handshake.future;
    return worker;
  }

  Future<String?> _safeGetWorkerError() async {
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
    } on Object {
      return null;
    }
  }

  Future<void> _runSingleRecovery(Future<void> Function() operation) async {
    final inFlight = _recoveryInFlight;
    if (inFlight != null) {
      await inFlight.future;
      return;
    }

    final completer = Completer<void>();
    _recoveryInFlight = completer;

    try {
      await operation();
      completer.complete();
    } on Object catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      if (identical(_recoveryInFlight, completer)) {
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
    await initialize();
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

  /// Shuts down the worker isolate and releases resources.
  ///
  /// Completes any pending requests with error before shutting down. Sends
  /// shutdown to the worker, kills the isolate, and closes the receive port.
  /// Call when the async connection is no longer needed. After `dispose`,
  /// `isInitialized` is false and `initialize` can be called again. In-flight
  /// requests will complete with [AsyncError] (workerTerminated).
  void dispose() {
    _isShuttingDown = true;
    _failAllPending(
      const AsyncError(
        code: AsyncErrorCode.workerTerminated,
        message: 'Connection disposed; worker shutting down',
      ),
    );
    _isInitialized = false;
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    _namedParamOrderByStmtId.clear();
    _connectionWorkerById.clear();
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

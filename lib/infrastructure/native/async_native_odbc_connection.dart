import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/core/di/async_backpressure_mode.dart';
import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/isolate/worker_isolate.dart';
import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/frame_accumulator.dart';
import 'package:odbc_fast/infrastructure/native/protocol/named_parameter_parser.dart'
    show NamedParameterParser, ParameterMissingException;
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

export 'package:odbc_fast/core/di/async_backpressure_mode.dart';

const _workerTerminatedSignal = '__odbc_fast_worker_terminated__';

class _BackpressureWaiter {
  _BackpressureWaiter();

  final Completer<void> completer = Completer<void>();
}

enum _WorkerMetricSample { latency, queueWait, execution }

class _WorkerChannel {
  _WorkerChannel({
    required this.index,
    required this.receivePort,
  });

  final int index;
  final ReceivePort receivePort;
  final Map<int, Completer<WorkerResponse>> pendingRequests = {};

  SendPort? sendPort;
  Isolate? isolate;
  int activeRequests = 0;
  int totalRouted = 0;
  int completedRequests = 0;
  int failedRequests = 0;
  int timeouts = 0;
  int fallbacksToBlocking = 0;
  int cancelAttempts = 0;
  int cancelSucceeded = 0;
  int cancelUnsupported = 0;
  int latencyTotalMicros = 0;
  int latencyMaxMicros = 0;
  int queueWaitTotalMicros = 0;
  int queueWaitMaxMicros = 0;
  int executionTotalMicros = 0;
  int executionMaxMicros = 0;
  final Queue<int> latencySamples = Queue<int>();
  final Queue<int> queueWaitSamples = Queue<int>();
  final Queue<int> executionSamples = Queue<int>();
  int _latencySamplesVersion = 0;
  int _queueWaitSamplesVersion = 0;
  int _executionSamplesVersion = 0;
  int _cachedLatencyP95Version = -1;
  int _cachedQueueWaitP95Version = -1;
  int _cachedExecutionP95Version = -1;
  int _cachedLatencyP95Micros = 0;
  int _cachedQueueWaitP95Micros = 0;
  int _cachedExecutionP95Micros = 0;

  bool get isReady => sendPort != null;

  Completer<WorkerResponse> send(WorkerRequest request) {
    final port = sendPort;
    if (port == null) {
      throw StateError('Worker $index not initialized');
    }
    final completer = Completer<WorkerResponse>();
    pendingRequests[request.requestId] = completer;
    activeRequests++;
    totalRouted++;
    port.send(request);
    return completer;
  }

  void complete(WorkerResponse response) {
    final completer = pendingRequests.remove(response.requestId);
    completer?.complete(response);
  }

  void removePending(int requestId) {
    pendingRequests.remove(requestId);
  }

  void finishRequest() {
    if (activeRequests > 0) {
      activeRequests--;
    }
  }

  void recordLatency(int micros) {
    latencyTotalMicros += micros;
    if (micros > latencyMaxMicros) {
      latencyMaxMicros = micros;
    }
    latencySamples.addLast(micros);
    if (latencySamples.length > 256) {
      latencySamples.removeFirst();
    }
    _latencySamplesVersion++;
  }

  void recordQueueWait(int micros) {
    queueWaitTotalMicros += micros;
    if (micros > queueWaitMaxMicros) {
      queueWaitMaxMicros = micros;
    }
    queueWaitSamples.addLast(micros);
    if (queueWaitSamples.length > 256) {
      queueWaitSamples.removeFirst();
    }
    _queueWaitSamplesVersion++;
  }

  void recordExecution(int micros) {
    executionTotalMicros += micros;
    if (micros > executionMaxMicros) {
      executionMaxMicros = micros;
    }
    executionSamples.addLast(micros);
    if (executionSamples.length > 256) {
      executionSamples.removeFirst();
    }
    _executionSamplesVersion++;
  }

  int percentileP95(_WorkerMetricSample sample) {
    final (samples, version, cachedVersion, cachedValue) = switch (sample) {
      _WorkerMetricSample.latency => (
          latencySamples,
          _latencySamplesVersion,
          _cachedLatencyP95Version,
          _cachedLatencyP95Micros,
        ),
      _WorkerMetricSample.queueWait => (
          queueWaitSamples,
          _queueWaitSamplesVersion,
          _cachedQueueWaitP95Version,
          _cachedQueueWaitP95Micros,
        ),
      _WorkerMetricSample.execution => (
          executionSamples,
          _executionSamplesVersion,
          _cachedExecutionP95Version,
          _cachedExecutionP95Micros,
        ),
    };
    if (version == cachedVersion) {
      return cachedValue;
    }
    final value = _percentile(samples, 95);
    switch (sample) {
      case _WorkerMetricSample.latency:
        _cachedLatencyP95Version = version;
        _cachedLatencyP95Micros = value;
      case _WorkerMetricSample.queueWait:
        _cachedQueueWaitP95Version = version;
        _cachedQueueWaitP95Micros = value;
      case _WorkerMetricSample.execution:
        _cachedExecutionP95Version = version;
        _cachedExecutionP95Micros = value;
    }
    return value;
  }

  static int _percentile(Iterable<int> samples, int percentile) {
    final sorted = samples.toList(growable: false)..sort();
    if (sorted.isEmpty) return 0;
    final index = ((sorted.length - 1) * percentile / 100).ceil();
    return sorted[index];
  }

  void failAll(AsyncError error) {
    final pending = Map<int, Completer<WorkerResponse>>.from(pendingRequests);
    pendingRequests.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    activeRequests = 0;
  }

  void dispose() {
    sendPort?.send('shutdown');
    isolate?.kill();
    receivePort.close();
    sendPort = null;
    isolate = null;
  }
}

final class AsyncWorkerStats {
  const AsyncWorkerStats({
    required this.index,
    required this.activeRequests,
    required this.pendingRequests,
    required this.totalRouted,
    required this.completedRequests,
    required this.failedRequests,
    required this.timeouts,
    required this.fallbacksToBlocking,
    required this.cancelAttempts,
    required this.cancelSucceeded,
    required this.cancelUnsupported,
    required this.latencyAvgMicros,
    required this.latencyP95Micros,
    required this.latencyMaxMicros,
    required this.queueWaitAvgMicros,
    required this.queueWaitP95Micros,
    required this.queueWaitMaxMicros,
    required this.executionAvgMicros,
    required this.executionP95Micros,
    required this.executionMaxMicros,
  });

  final int index;
  final int activeRequests;
  final int pendingRequests;
  final int totalRouted;
  final int completedRequests;
  final int failedRequests;
  final int timeouts;
  final int fallbacksToBlocking;
  final int cancelAttempts;
  final int cancelSucceeded;
  final int cancelUnsupported;
  final int latencyAvgMicros;
  final int latencyP95Micros;
  final int latencyMaxMicros;
  final int queueWaitAvgMicros;
  final int queueWaitP95Micros;
  final int queueWaitMaxMicros;
  final int executionAvgMicros;
  final int executionP95Micros;
  final int executionMaxMicros;
}

/// Snapshot of async worker pool counters.
///
/// Values are captured when
/// [AsyncNativeOdbcConnection.getWorkerPoolStats] is called and are maintained
/// entirely on the Dart side.
final class AsyncWorkerPoolStats {
  const AsyncWorkerPoolStats({
    required this.workerCount,
    required this.activeRequests,
    required this.pendingRequests,
    required this.totalRouted,
    required this.completedRequests,
    required this.failedRequests,
    required this.timeouts,
    required this.fallbacksToBlocking,
    required this.cancelAttempts,
    required this.cancelSucceeded,
    required this.cancelUnsupported,
    required this.latencyAvgMicros,
    required this.latencyP95Micros,
    required this.latencyMaxMicros,
    required this.queueWaitAvgMicros,
    required this.queueWaitP95Micros,
    required this.queueWaitMaxMicros,
    required this.executionAvgMicros,
    required this.executionP95Micros,
    required this.executionMaxMicros,
    required this.workers,
  });

  /// Configured number of worker isolates.
  final int workerCount;

  /// Requests currently in flight across all workers.
  final int activeRequests;

  /// Requests awaiting a response across all workers.
  final int pendingRequests;

  /// Total requests routed to workers since initialization.
  final int totalRouted;

  /// Total requests completed without a response-level error.
  final int completedRequests;

  /// Total requests that timed out, threw, or returned a response-level error.
  final int failedRequests;

  /// Requests that timed out while waiting for a worker response.
  final int timeouts;

  /// Parameterized async starts that fell back to the blocking query path.
  final int fallbacksToBlocking;

  final int cancelAttempts;
  final int cancelSucceeded;
  final int cancelUnsupported;
  final int latencyAvgMicros;
  final int latencyP95Micros;
  final int latencyMaxMicros;
  final int queueWaitAvgMicros;
  final int queueWaitP95Micros;
  final int queueWaitMaxMicros;
  final int executionAvgMicros;
  final int executionP95Micros;
  final int executionMaxMicros;
  final List<AsyncWorkerStats> workers;
}

/// Non-blocking wrapper around ODBC using a long-lived worker isolate.
///
/// **Architecture**: All FFI/ODBC operations run in a dedicated worker isolate.
/// The main thread stays responsive; no blocking FFI calls run on the UI
/// thread.
///
/// ## How it works
///
/// 1. [initialize] spawns a worker isolate and loads the ODBC driver.
/// 2. Each operation sends a request (via [SendPort]) to the worker.
/// 3. The worker runs the FFI call and sends back the result (via
///    [ReceivePort]).
/// 4. The main thread never blocks on ODBC.
///
/// ## Performance
///
/// - Worker spawn (one-time): ~50–100 ms.
/// - Per-operation overhead: ~1–3 ms.
/// - Parallel queries: N queries complete in the time of the longest (not
///   the sum).
///
/// ## Request timeout
///
/// Use `requestTimeout` to avoid UI hangs when the worker does not respond
/// (default 30s). Pass `Duration.zero` or `null` to disable.
///
/// ## Example
///
/// ```dart
/// final async = AsyncNativeOdbcConnection(
///   requestTimeout: Duration(seconds: 30),
/// );
/// await async.initialize();
///
/// final connId = await async.connect(dsn);
/// final data = await async.executeQueryParams(connId, 'SELECT 1', []);
/// await async.disconnect(connId);
///
/// async.dispose(); // Pending requests complete with error
/// ```
///
/// See also:
/// - `worker_isolate.dart` for the worker entry and request handling.
/// - [WorkerRequest] and [WorkerResponse] for the message protocol.
class AsyncNativeOdbcConnection {
  AsyncNativeOdbcConnection({
    Duration? requestTimeout,
    void Function(SendPort)? isolateEntry,
    this.autoRecoverOnWorkerCrash = false,
    this.workerCount = 1,
    this.maxPendingRequests,
    this.backpressureMode = AsyncBackpressureMode.failFast,
    this.backpressureTimeout,
  })  : _requestTimeout = requestTimeout,
        _isolateEntry = isolateEntry {
    if (workerCount < 1) {
      throw ArgumentError.value(
        workerCount,
        'workerCount',
        'must be greater than or equal to 1',
      );
    }
    final pendingLimit = maxPendingRequests;
    if (pendingLimit != null && pendingLimit < 1) {
      throw ArgumentError.value(
        pendingLimit,
        'maxPendingRequests',
        'must be null or greater than or equal to 1',
      );
    }
    final pendingTimeout = backpressureTimeout;
    if (pendingTimeout != null && pendingTimeout < Duration.zero) {
      throw ArgumentError.value(
        pendingTimeout,
        'backpressureTimeout',
        'must be null, zero, or greater than zero',
      );
    }
  }

  static const _defaultRequestTimeout = Duration(seconds: 30);
  static const _streamAsyncStatusPending = 0;
  static const _streamAsyncStatusReady = 1;
  static const _streamAsyncStatusDone = 2;
  static const _streamAsyncStatusError = -1;
  static const _streamAsyncStatusCancelled = -2;

  final Duration? _requestTimeout;

  /// Test hook: custom isolate entry. When set, used instead of [workerEntry].
  final void Function(SendPort)? _isolateEntry;

  /// Number of worker isolates used by this async connection.
  ///
  /// The default is 1 to preserve the historical behavior. Use values greater
  /// than 1 only when concurrent work uses multiple connections or pool
  /// checkouts; operations on the same connection are still serialized by the
  /// native connection mutex.
  final int workerCount;

  /// Optional global limit for requests awaiting worker responses.
  ///
  /// `null` preserves the historical unbounded behavior. Use a small multiple
  /// of native pool size for high-concurrency pool workloads.
  final int? maxPendingRequests;

  /// Behavior when [maxPendingRequests] has been reached.
  final AsyncBackpressureMode backpressureMode;

  /// Timeout while waiting for a queue slot in
  /// [AsyncBackpressureMode.waitForSlot].
  final Duration? backpressureTimeout;

  /// When true, on worker isolate error/done
  /// `WorkerCrashRecovery.handleWorkerCrash` is invoked after failing pending
  /// requests. All previous connection IDs are invalid after recovery; callers
  /// must reconnect.
  final bool autoRecoverOnWorkerCrash;

  final List<_WorkerChannel> _workers = [];
  bool _isInitialized = false;
  bool _isShuttingDown = false;
  int _requestIdCounter = 0;
  final Map<int, List<String>> _namedParamOrderByStmtId = {};
  final Map<int, int> _connectionWorkerById = {};
  final Map<int, int> _statementWorkerById = {};
  final Map<int, int> _statementConnectionById = {};
  final Map<int, int> _transactionWorkerById = {};
  final Map<int, int> _streamWorkerById = {};
  final Map<int, int> _asyncRequestWorkerById = {};
  final Queue<_BackpressureWaiter> _backpressureWaiters =
      Queue<_BackpressureWaiter>();
  int _backpressureSlotsReserved = 0;
  int _cachedAggregateLatencyP95Version = -1;
  int _cachedAggregateQueueWaitP95Version = -1;
  int _cachedAggregateExecutionP95Version = -1;
  int _cachedAggregateLatencyP95Micros = 0;
  int _cachedAggregateQueueWaitP95Micros = 0;
  int _cachedAggregateExecutionP95Micros = 0;
  Completer<void>? _recoveryInFlight;

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
                throw AsyncError(
                  code: AsyncErrorCode.requestTimeout,
                  message:
                      'Worker ${targetWorker.index} did not respond within '
                      '${effectiveTimeout.inSeconds}s',
                );
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
      CancelStatementRequest() => _leastLoadedWorker(),
      CommitTransactionRequest(:final txnId) ||
      RollbackTransactionRequest(:final txnId) ||
      SavepointCreateRequest(:final txnId) ||
      SavepointRollbackRequest(:final txnId) ||
      SavepointReleaseRequest(:final txnId) =>
        _workerForTransaction(txnId),
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
      StreamPollAsyncRequest(:final streamId) =>
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
      case (BeginTransactionRequest(), IntResponse(value: final id))
          when id > 0:
        _transactionWorkerById[id] = worker.index;
      case (
            CommitTransactionRequest(:final txnId),
            BoolResponse(:final value),
          )
          when value:
      case (
            RollbackTransactionRequest(:final txnId),
            BoolResponse(:final value),
          )
          when value:
        _transactionWorkerById.remove(txnId);
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
  }

  void _clearWorkerAffinity(int workerIndex) {
    _connectionWorkerById.entries
        .where((entry) => entry.value == workerIndex)
        .map((entry) => entry.key)
        .toList(growable: false)
        .forEach(_clearConnectionAffinity);

    _statementWorkerById.removeWhere((_, value) => value == workerIndex);
    _transactionWorkerById.removeWhere((_, value) => value == workerIndex);
    _streamWorkerById.removeWhere((_, value) => value == workerIndex);
    _asyncRequestWorkerById.removeWhere((_, value) => value == workerIndex);
  }

  Future<String?> _safeGetWorkerError() async {
    try {
      final message = await getError();
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
  }

  /// Whether the worker isolate and ODBC environment are initialized.
  bool get isInitialized => _isInitialized;

  /// Returns a Dart-side snapshot of worker pool routing and health counters.
  AsyncWorkerPoolStats getWorkerPoolStats() {
    final workers = _workers.map(_statsForWorker).toList(growable: false);
    return AsyncWorkerPoolStats(
      workerCount: workerCount,
      activeRequests: workers.fold<int>(
        0,
        (total, worker) => total + worker.activeRequests,
      ),
      pendingRequests: workers.fold<int>(
        0,
        (total, worker) => total + worker.pendingRequests,
      ),
      totalRouted: workers.fold<int>(
        0,
        (total, worker) => total + worker.totalRouted,
      ),
      completedRequests: workers.fold<int>(
        0,
        (total, worker) => total + worker.completedRequests,
      ),
      failedRequests: workers.fold<int>(
        0,
        (total, worker) => total + worker.failedRequests,
      ),
      timeouts: workers.fold<int>(
        0,
        (total, worker) => total + worker.timeouts,
      ),
      fallbacksToBlocking: workers.fold<int>(
        0,
        (total, worker) => total + worker.fallbacksToBlocking,
      ),
      cancelAttempts: workers.fold<int>(
        0,
        (total, worker) => total + worker.cancelAttempts,
      ),
      cancelSucceeded: workers.fold<int>(
        0,
        (total, worker) => total + worker.cancelSucceeded,
      ),
      cancelUnsupported: workers.fold<int>(
        0,
        (total, worker) => total + worker.cancelUnsupported,
      ),
      latencyAvgMicros: _weightedAverageLatency(),
      latencyP95Micros: _aggregateP95(_WorkerMetricSample.latency),
      latencyMaxMicros: workers.fold<int>(
        0,
        (max, worker) =>
            worker.latencyMaxMicros > max ? worker.latencyMaxMicros : max,
      ),
      queueWaitAvgMicros: _weightedAverage(
        (worker) => worker.queueWaitTotalMicros,
      ),
      queueWaitP95Micros: _aggregateP95(_WorkerMetricSample.queueWait),
      queueWaitMaxMicros: workers.fold<int>(
        0,
        (max, worker) =>
            worker.queueWaitMaxMicros > max ? worker.queueWaitMaxMicros : max,
      ),
      executionAvgMicros: _weightedAverage(
        (worker) => worker.executionTotalMicros,
      ),
      executionP95Micros: _aggregateP95(_WorkerMetricSample.execution),
      executionMaxMicros: workers.fold<int>(
        0,
        (max, worker) =>
            worker.executionMaxMicros > max ? worker.executionMaxMicros : max,
      ),
      workers: workers,
    );
  }

  AsyncWorkerStats _statsForWorker(_WorkerChannel worker) {
    final completed = worker.completedRequests + worker.failedRequests;
    return AsyncWorkerStats(
      index: worker.index,
      activeRequests: worker.activeRequests,
      pendingRequests: worker.pendingRequests.length,
      totalRouted: worker.totalRouted,
      completedRequests: worker.completedRequests,
      failedRequests: worker.failedRequests,
      timeouts: worker.timeouts,
      fallbacksToBlocking: worker.fallbacksToBlocking,
      cancelAttempts: worker.cancelAttempts,
      cancelSucceeded: worker.cancelSucceeded,
      cancelUnsupported: worker.cancelUnsupported,
      latencyAvgMicros:
          completed == 0 ? 0 : worker.latencyTotalMicros ~/ completed,
      latencyP95Micros: worker.percentileP95(_WorkerMetricSample.latency),
      latencyMaxMicros: worker.latencyMaxMicros,
      queueWaitAvgMicros:
          completed == 0 ? 0 : worker.queueWaitTotalMicros ~/ completed,
      queueWaitP95Micros: worker.percentileP95(_WorkerMetricSample.queueWait),
      queueWaitMaxMicros: worker.queueWaitMaxMicros,
      executionAvgMicros:
          completed == 0 ? 0 : worker.executionTotalMicros ~/ completed,
      executionP95Micros: worker.percentileP95(_WorkerMetricSample.execution),
      executionMaxMicros: worker.executionMaxMicros,
    );
  }

  int _weightedAverageLatency() {
    return _weightedAverage((worker) => worker.latencyTotalMicros);
  }

  int _weightedAverage(int Function(_WorkerChannel worker) totalForWorker) {
    var totalMicros = 0;
    var totalRequests = 0;
    for (final worker in _workers) {
      totalMicros += totalForWorker(worker);
      totalRequests += worker.completedRequests + worker.failedRequests;
    }
    if (totalRequests == 0) return 0;
    return totalMicros ~/ totalRequests;
  }

  int _aggregateP95(_WorkerMetricSample sample) {
    final version = switch (sample) {
      _WorkerMetricSample.latency => _workers.fold<int>(
          0,
          (sum, worker) => sum + worker._latencySamplesVersion,
        ),
      _WorkerMetricSample.queueWait => _workers.fold<int>(
          0,
          (sum, worker) => sum + worker._queueWaitSamplesVersion,
        ),
      _WorkerMetricSample.execution => _workers.fold<int>(
          0,
          (sum, worker) => sum + worker._executionSamplesVersion,
        ),
    };
    final cached = switch (sample) {
      _WorkerMetricSample.latency => (
          _cachedAggregateLatencyP95Version,
          _cachedAggregateLatencyP95Micros,
        ),
      _WorkerMetricSample.queueWait => (
          _cachedAggregateQueueWaitP95Version,
          _cachedAggregateQueueWaitP95Micros,
        ),
      _WorkerMetricSample.execution => (
          _cachedAggregateExecutionP95Version,
          _cachedAggregateExecutionP95Micros,
        ),
    };
    if (version == cached.$1) {
      return cached.$2;
    }

    final value = _percentileLatency(
      switch (sample) {
        _WorkerMetricSample.latency => _workers.expand(
            (worker) => worker.latencySamples,
          ),
        _WorkerMetricSample.queueWait => _workers.expand(
            (worker) => worker.queueWaitSamples,
          ),
        _WorkerMetricSample.execution => _workers.expand(
            (worker) => worker.executionSamples,
          ),
      },
      95,
    );
    switch (sample) {
      case _WorkerMetricSample.latency:
        _cachedAggregateLatencyP95Version = version;
        _cachedAggregateLatencyP95Micros = value;
      case _WorkerMetricSample.queueWait:
        _cachedAggregateQueueWaitP95Version = version;
        _cachedAggregateQueueWaitP95Micros = value;
      case _WorkerMetricSample.execution:
        _cachedAggregateExecutionP95Version = version;
        _cachedAggregateExecutionP95Micros = value;
    }
    return value;
  }

  int _percentileLatency(Iterable<int> samples, int percentile) {
    final sorted = samples.toList(growable: false)..sort();
    if (sorted.isEmpty) return 0;
    final index = ((sorted.length - 1) * percentile / 100).ceil();
    return sorted[index];
  }

  int get affinityEntryCountForTesting =>
      _connectionWorkerById.length +
      _statementWorkerById.length +
      _statementConnectionById.length +
      _transactionWorkerById.length +
      _streamWorkerById.length +
      _asyncRequestWorkerById.length;

  void failWorkerForTesting(int workerIndex) {
    final worker = _workerByIndex(workerIndex);
    if (worker == null) return;
    worker.failAll(
      const AsyncError(
        code: AsyncErrorCode.workerTerminated,
        message: 'Worker isolate terminated',
      ),
    );
    _clearWorkerAffinity(worker.index);
    _drainBackpressureWaiters();
  }

  /// Worker isolate, exposed for testing (e.g., to simulate crash).
  Isolate? get workerIsolateForTesting =>
      _workers.isEmpty ? null : _workers.first.isolate;

  /// Opens a connection in the worker using [connectionString].
  ///
  /// [timeoutMs] is the login timeout in milliseconds (0 = driver default).
  /// Throws [AsyncError] with [AsyncErrorCode.connectionFailed] if the
  /// connection fails. Call [initialize] before [connect].
  ///
  /// Returns the native connection ID (positive integer) on success.
  Future<int> connect(String connectionString, {int timeoutMs = 0}) async {
    if (!_isInitialized) {
      throw const AsyncError(
        code: AsyncErrorCode.notInitialized,
        message: 'Environment not initialized. Call initialize() first.',
      );
    }
    final r = await _sendRequest<ConnectResponse>(
      ConnectRequest(_nextRequestId(), connectionString, timeoutMs: timeoutMs),
    );
    if (r.error != null) {
      throw AsyncError(
        code: AsyncErrorCode.connectionFailed,
        message: r.error!,
      );
    }
    return r.connectionId;
  }

  /// Closes the connection identified by [connectionId] in the worker.
  ///
  /// Returns `true` if disconnect succeeded, `false` otherwise.
  Future<bool> disconnect(int connectionId) async {
    final r = await _sendRequest<BoolResponse>(
      DisconnectRequest(_nextRequestId(), connectionId),
    );
    return r.value;
  }

  /// Returns the last error message from the worker (plain text).
  Future<String> getError() async {
    final r =
        await _sendRequest<GetErrorResponse>(GetErrorRequest(_nextRequestId()));
    return r.message;
  }

  /// Detects the database driver from a connection string.
  ///
  /// Returns the driver name (e.g. "sqlserver", "oracle", "postgres") if
  /// detected, or null if unknown.
  Future<String?> detectDriver(String connectionString) async {
    final r = await _sendRequest<DetectDriverResponse>(
      DetectDriverRequest(_nextRequestId(), connectionString),
    );
    return r.driverName;
  }

  /// Validates connection string format without opening a connection.
  ///
  /// Returns null when valid; otherwise a human-readable validation message.
  Future<String?> validateConnectionString(String connectionString) async {
    final r = await _sendRequest<ValidateConnectionStringResponse>(
      ValidateConnectionStringRequest(_nextRequestId(), connectionString),
    );
    if (r.isValid) {
      return null;
    }
    return r.errorMessage ?? 'Invalid connection string';
  }

  /// Returns driver capabilities payload as JSON, or null on failure.
  Future<String?> getDriverCapabilitiesJson(String connectionString) async {
    final r = await _sendRequest<AuditPayloadResponse>(
      GetDriverCapabilitiesRequest(_nextRequestId(), connectionString),
    );
    if (r.error != null) {
      return null;
    }
    return r.payload;
  }

  /// Returns live DBMS introspection payload as JSON, or null on failure.
  Future<String?> getConnectionDbmsInfoJson(int connectionId) async {
    final r = await _sendRequest<AuditPayloadResponse>(
      GetConnectionDbmsInfoRequest(_nextRequestId(), connectionId),
    );
    if (r.error != null) {
      return null;
    }
    return r.payload;
  }

  /// Sets native engine log verbosity in the worker.
  Future<void> setLogLevel(int level) async {
    await _sendRequest<BoolResponse>(
      SetLogLevelRequest(_nextRequestId(), level),
    );
  }

  /// Returns the last structured error (message, SQLSTATE, native code), or
  /// `null` if there is no error.
  Future<StructuredError?> getStructuredError() async {
    final r = await _sendRequest<StructuredErrorResponse>(
      GetStructuredErrorRequest(_nextRequestId()),
    );
    if (r.error != null) return null;
    if (r.message.isEmpty && r.sqlStateString == null) return null;
    final sqlState = (r.sqlStateString ?? '').codeUnits;
    return StructuredError(
      message: r.message,
      sqlState: sqlState.isNotEmpty ? sqlState : List.filled(5, 0),
      nativeCode: r.nativeCode ?? 0,
    );
  }

  /// Returns the last structured error for [connectionId], or `null` when
  /// there is no connection-scoped error information.
  Future<StructuredError?> getStructuredErrorForConnection(
    int connectionId,
  ) async {
    final r = await _sendRequest<StructuredErrorResponse>(
      GetStructuredErrorForConnectionRequest(
        _nextRequestId(),
        connectionId,
      ),
    );
    if (r.error != null) return null;
    if (r.message.isEmpty && r.sqlStateString == null) return null;
    final sqlState = (r.sqlStateString ?? '').codeUnits;
    return StructuredError(
      message: r.message,
      sqlState: sqlState.isNotEmpty ? sqlState : List.filled(5, 0),
      nativeCode: r.nativeCode ?? 0,
    );
  }

  /// Starts non-blocking query execution in native layer.
  ///
  /// Returns async request ID (>0) on success, or 0 on failure.
  Future<int> executeAsyncStart(int connectionId, String sql) async {
    final r = await _sendRequest<IntResponse>(
      ExecuteAsyncStartRequest(_nextRequestId(), connectionId, sql),
    );
    return r.value;
  }

  /// Starts non-blocking parameterized execution in native layer.
  ///
  /// Returns async request ID (>0) on success, or 0 on failure/API fallback.
  Future<int> executeAsyncStartParams(
    int connectionId,
    String sql,
    Uint8List? serializedParams,
  ) async {
    final bytes = serializedParams == null || serializedParams.isEmpty
        ? Uint8List(0)
        : serializedParams;
    final r = await _sendRequest<IntResponse>(
      ExecuteAsyncStartParamsRequest(
        _nextRequestId(),
        connectionId,
        sql,
        bytes,
      ),
    );
    return r.value;
  }

  /// Polls async request status.
  ///
  /// Status values: `0` pending, `1` ready, `-1` error, `-2` cancelled.
  Future<int> asyncPoll(int asyncRequestId) async {
    final r = await _sendRequest<IntResponse>(
      AsyncPollRequest(_nextRequestId(), asyncRequestId),
    );
    return r.value;
  }

  /// Retrieves binary result for a completed async request.
  ///
  /// Returns null when request is not ready or has failed.
  Future<Uint8List?> asyncGetResult(
    int asyncRequestId, {
    int? maxBufferBytes,
  }) async {
    final r = await _sendRequest<QueryResponse>(
      AsyncGetResultRequest(
        _nextRequestId(),
        asyncRequestId,
        maxResultBufferBytes: maxBufferBytes,
      ),
    );
    if (r.error != null) {
      return null;
    }
    return r.data;
  }

  /// Executes [sql] in non-blocking mode using native async request lifecycle.
  ///
  /// Flow: `start -> poll -> get_result -> free`.
  /// Returns the binary result when execution completes successfully, or `null`
  /// on failure/cancellation/timeout.
  Future<Uint8List?> executeAsync(
    int connectionId,
    String sql, {
    Duration pollInterval = const Duration(milliseconds: 10),
    Duration? timeout,
    int? maxBufferBytes,
  }) async {
    final requestId = await executeAsyncStart(connectionId, sql);
    if (requestId <= 0) {
      return null;
    }
    return _waitForAsyncResult(
      requestId,
      pollInterval: pollInterval,
      timeout: timeout,
      maxBufferBytes: maxBufferBytes,
    );
  }

  Future<Uint8List?> _waitForAsyncResult(
    int requestId, {
    Duration pollInterval = const Duration(milliseconds: 10),
    Duration? timeout,
    int? maxBufferBytes,
  }) async {
    final effectiveTimeout =
        timeout ?? _requestTimeout ?? _defaultRequestTimeout;
    final timeoutStopwatch = Stopwatch()..start();

    try {
      while (true) {
        final status = await asyncPoll(requestId);

        switch (status) {
          case 1: // ready
            return asyncGetResult(
              requestId,
              maxBufferBytes: maxBufferBytes,
            );
          case 0: // pending
            if (effectiveTimeout > Duration.zero &&
                timeoutStopwatch.elapsed >= effectiveTimeout) {
              await asyncCancel(requestId);
              return null;
            }
            await Future<void>.delayed(pollInterval);
          case -1: // error
          case -2: // cancelled
            return null;
          default:
            return null;
        }
      }
    } finally {
      await asyncFree(requestId);
    }
  }

  /// Best-effort cancellation for async request.
  Future<bool> asyncCancel(int asyncRequestId) async {
    final r = await _sendRequest<BoolResponse>(
      AsyncCancelRequest(_nextRequestId(), asyncRequestId),
    );
    return r.value;
  }

  /// Frees async request resources.
  Future<bool> asyncFree(int asyncRequestId) async {
    final r = await _sendRequest<BoolResponse>(
      AsyncFreeRequest(_nextRequestId(), asyncRequestId),
    );
    return r.value;
  }

  /// Enables/disables native audit event collection in the worker.
  Future<bool> setAuditEnabled({required bool enabled}) async {
    final r = await _sendRequest<BoolResponse>(
      AuditEnableRequest(_nextRequestId(), enabled: enabled),
    );
    return r.value;
  }

  /// Clears in-memory audit events in the worker.
  Future<bool> clearAuditEvents() async {
    final r = await _sendRequest<BoolResponse>(
      AuditClearRequest(_nextRequestId()),
    );
    return r.value;
  }

  /// Returns audit events as JSON payload, or null on failure.
  Future<String?> getAuditEventsJson({int limit = 0}) async {
    final r = await _sendRequest<AuditPayloadResponse>(
      AuditGetEventsRequest(_nextRequestId(), limit: limit),
    );
    if (r.error != null) {
      return null;
    }
    return r.payload;
  }

  /// Returns audit status as JSON payload, or null on failure.
  Future<String?> getAuditStatusJson() async {
    final r = await _sendRequest<AuditPayloadResponse>(
      AuditGetStatusRequest(_nextRequestId()),
    );
    if (r.error != null) {
      return null;
    }
    return r.payload;
  }

  /// Starts a transaction in the worker for [connectionId] with
  /// [isolationLevel]. Returns the transaction ID on success.
  ///
  /// [savepointDialect] is the wire code from `SavepointDialect.code`
  /// (default `0` = `auto`, resolved by the Rust engine via SQLGetInfo).
  /// [accessMode] is the wire code from `TransactionAccessMode.code`
  /// (default `0` = `readWrite`). Sprint 4.1.
  /// [lockTimeoutMs] is the per-transaction lock timeout in milliseconds
  /// (default `0` = engine default). Sprint 4.2.
  Future<int> beginTransaction(
    int connectionId,
    int isolationLevel, {
    int savepointDialect = 0,
    int accessMode = 0,
    int lockTimeoutMs = 0,
  }) async {
    final r = await _sendRequest<IntResponse>(
      BeginTransactionRequest(
        _nextRequestId(),
        connectionId,
        isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeoutMs: lockTimeoutMs,
      ),
    );
    return r.value;
  }

  /// Commits the transaction identified by [txnId] in the worker.
  Future<bool> commitTransaction(int txnId) async {
    final r = await _sendRequest<BoolResponse>(
      CommitTransactionRequest(_nextRequestId(), txnId),
    );
    return r.value;
  }

  /// Rolls back the transaction identified by [txnId] in the worker.
  Future<bool> rollbackTransaction(int txnId) async {
    final r = await _sendRequest<BoolResponse>(
      RollbackTransactionRequest(_nextRequestId(), txnId),
    );
    return r.value;
  }

  /// Creates a savepoint [name] within the transaction [txnId] in the worker.
  Future<bool> createSavepoint(int txnId, String name) async {
    final r = await _sendRequest<BoolResponse>(
      SavepointCreateRequest(_nextRequestId(), txnId, name),
    );
    return r.value;
  }

  /// Rolls back to savepoint [name] in transaction [txnId].
  /// Transaction stays active.
  Future<bool> rollbackToSavepoint(int txnId, String name) async {
    final r = await _sendRequest<BoolResponse>(
      SavepointRollbackRequest(_nextRequestId(), txnId, name),
    );
    return r.value;
  }

  /// Releases savepoint [name] in transaction [txnId].
  /// Transaction stays active.
  Future<bool> releaseSavepoint(int txnId, String name) async {
    final r = await _sendRequest<BoolResponse>(
      SavepointReleaseRequest(_nextRequestId(), txnId, name),
    );
    return r.value;
  }

  /// Prepares [sql] on [connectionId] in the worker.
  ///
  /// [timeoutMs] is the statement execution timeout (0 = no limit).
  /// Returns the statement ID on success.
  Future<int> prepare(int connectionId, String sql, {int timeoutMs = 0}) async {
    final r = await _sendRequest<IntResponse>(
      PrepareRequest(_nextRequestId(), connectionId, sql, timeoutMs: timeoutMs),
    );
    return r.value;
  }

  /// Prepares [sql] with named parameters on [connectionId] in the worker.
  ///
  /// Supports `@name` and `:name` syntax. Named placeholders are converted
  /// to positional placeholders before prepare. All placeholder occurrences
  /// are preserved so repeated names can reuse the same input value during
  /// execution. On success, internal metadata is stored so
  /// [executePreparedNamed] can bind values by name.
  Future<int> prepareNamed(
    int connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    final extract = NamedParameterParser.extract(sql);
    final stmtId = await prepare(
      connectionId,
      extract.cleanedSql,
      timeoutMs: timeoutMs,
    );
    if (stmtId > 0) {
      _namedParamOrderByStmtId[stmtId] = extract.paramNames;
    }
    return stmtId;
  }

  /// Executes a prepared statement [stmtId] in the worker with optional
  /// [params]. Returns the binary result, or `null` on error.
  Future<Uint8List?> executePrepared(
    int stmtId,
    List<ParamValue>? params,
    int timeoutOverrideMs,
    int fetchSize, {
    int? maxBufferBytes,
  }) async {
    final bytes =
        params == null || params.isEmpty ? null : serializeParams(params);
    final r = await _sendRequest<QueryResponse>(
      ExecutePreparedRequest(
        _nextRequestId(),
        stmtId,
        bytes ?? Uint8List(0),
        timeoutOverrideMs: timeoutOverrideMs,
        fetchSize: fetchSize,
        maxResultBufferBytes: maxBufferBytes,
      ),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Executes a prepared statement [stmtId] using named parameters.
  ///
  /// The [stmtId] must come from [prepareNamed]. Throws [AsyncError] with
  /// [AsyncErrorCode.invalidParameter] when named parameter metadata is
  /// missing or required parameters are not provided. Repeated placeholders
  /// reuse the same value from [namedParams].
  Future<Uint8List?> executePreparedNamed(
    int stmtId,
    Map<String, Object?> namedParams,
    int timeoutOverrideMs,
    int fetchSize, {
    int? maxBufferBytes,
  }) async {
    final paramOrder = _namedParamOrderByStmtId[stmtId];
    if (paramOrder == null) {
      throw const AsyncError(
        code: AsyncErrorCode.invalidParameter,
        message: 'Statement was not prepared with prepareNamed',
      );
    }

    try {
      final positional = NamedParameterParser.toPositionalParams(
        namedParams: namedParams,
        paramNames: paramOrder,
      );
      final paramValues = paramValuesFromObjects(positional);
      return executePrepared(
        stmtId,
        paramValues,
        timeoutOverrideMs,
        fetchSize,
        maxBufferBytes: maxBufferBytes,
      );
    } on ParameterMissingException catch (e) {
      throw AsyncError(
        code: AsyncErrorCode.invalidParameter,
        message: e.message,
      );
    }
  }

  /// Executes [sql] on [connectionId] with [params] in the worker.
  ///
  /// When [maxBufferBytes] is set, caps the result buffer size.
  /// Returns the binary result (same format as sync API), or `null` on error.
  Future<Uint8List?> executeQueryParams(
    int connectionId,
    String sql,
    List<ParamValue> params, {
    int? maxBufferBytes,
    Duration? timeout,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    final bytes = params.isEmpty ? Uint8List(0) : serializeParams(params);
    return executeQueryParamBuffer(
      connectionId,
      sql,
      bytes,
      maxBufferBytes: maxBufferBytes,
      timeout: timeout,
      resultEncoding: resultEncoding,
    );
  }

  Future<Uint8List?> _executeQueryParamsBlocking(
    int connectionId,
    String sql,
    Uint8List bytes, {
    int? maxBufferBytes,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    final r = await _sendRequest<QueryResponse>(
      ExecuteQueryParamsRequest(
        _nextRequestId(),
        connectionId,
        sql,
        bytes,
        maxResultBufferBytes: maxBufferBytes,
        resultEncoding: resultEncoding,
      ),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Executes a parameterised query with a pre-serialised buffer (legacy v0 or
  /// DRT1 directed parameters).
  Future<Uint8List?> executeQueryParamBuffer(
    int connectionId,
    String sql,
    Uint8List? paramBuffer, {
    int? maxBufferBytes,
    Duration? timeout,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    final bytes =
        paramBuffer == null || paramBuffer.isEmpty ? Uint8List(0) : paramBuffer;
    if (resultEncoding == ResultEncoding.rowMajor) {
      final asyncRequestId = await executeAsyncStartParams(
        connectionId,
        sql,
        bytes,
      );
      if (asyncRequestId > 0) {
        return _waitForAsyncResult(
          asyncRequestId,
          maxBufferBytes: maxBufferBytes,
          timeout: timeout,
        );
      }
    }

    _recordFallbackToBlocking(connectionId);
    return _executeQueryParamsBlocking(
      connectionId,
      sql,
      bytes,
      maxBufferBytes: maxBufferBytes,
      resultEncoding: resultEncoding,
    );
  }

  /// Executes [sql] on [connectionId] using named parameters.
  ///
  /// Supports `@name` and `:name` syntax, converting placeholders to
  /// positional order before sending the query to the worker. Repeated
  /// placeholders reuse the same value from [namedParams].
  ///
  /// Throws [AsyncError] with [AsyncErrorCode.invalidParameter] when any
  /// required named parameter is missing.
  Future<Uint8List?> executeQueryNamed(
    int connectionId,
    String sql,
    Map<String, Object?> namedParams, {
    int? maxBufferBytes,
  }) async {
    try {
      final extract = NamedParameterParser.extract(sql);
      final positional = NamedParameterParser.toPositionalParams(
        namedParams: namedParams,
        paramNames: extract.paramNames,
      );
      final paramValues = paramValuesFromObjects(positional);
      return executeQueryParams(
        connectionId,
        extract.cleanedSql,
        paramValues,
        maxBufferBytes: maxBufferBytes,
      );
    } on ParameterMissingException catch (e) {
      throw AsyncError(
        code: AsyncErrorCode.invalidParameter,
        message: e.message,
      );
    }
  }

  /// Executes [sql] on [connectionId] for multi-result sets in the worker.
  /// When [maxBufferBytes] is set, caps the result buffer size.
  /// Returns the binary result, or `null` on error.
  Future<Uint8List?> executeQueryMulti(
    int connectionId,
    String sql, {
    int? maxBufferBytes,
  }) async {
    final r = await _sendRequest<QueryResponse>(
      ExecuteQueryMultiRequest(
        _nextRequestId(),
        connectionId,
        sql,
        maxResultBufferBytes: maxBufferBytes,
      ),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Executes a parameterised multi-result batch in the worker.
  ///
  /// `paramsBuffer` is the output of `serializeParams(...)`. Pass `null` for
  /// no parameters. New in v3.2.0 (M5).
  Future<Uint8List?> executeQueryMultiParams(
    int connectionId,
    String sql,
    Uint8List? paramsBuffer, {
    int? maxBufferBytes,
  }) async {
    final r = await _sendRequest<QueryResponse>(
      ExecuteQueryMultiParamsRequest(
        _nextRequestId(),
        connectionId,
        sql,
        paramsBuffer ?? Uint8List(0),
        maxResultBufferBytes: maxBufferBytes,
      ),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Requests cancellation of prepared statement [stmtId] in the worker.
  ///
  /// Returns `true` if cancellation request succeeded, `false` otherwise.
  Future<bool> cancelStatement(int stmtId) async {
    final r = await _sendRequest<BoolResponse>(
      CancelStatementRequest(_nextRequestId(), stmtId),
    );
    return r.value;
  }

  /// Closes the prepared statement [stmtId] in the worker.
  Future<bool> closeStatement(int stmtId) async {
    try {
      final r = await _sendRequest<BoolResponse>(
        CloseStatementRequest(_nextRequestId(), stmtId),
      );
      return r.value;
    } finally {
      _namedParamOrderByStmtId.remove(stmtId);
    }
  }

  Future<int> clearAllStatements() async {
    final r = await _sendRequest<IntResponse>(
      ClearAllStatementsRequest(_nextRequestId()),
    );
    if (r.value == 0) {
      _namedParamOrderByStmtId.clear();
    }
    return r.value;
  }

  /// Returns catalog tables for [connectionId] (optional [catalog] and
  /// [schema]). Returns binary result or `null` on error.
  Future<Uint8List?> catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
  }) async {
    final r = await _sendRequest<QueryResponse>(
      CatalogTablesRequest(
        _nextRequestId(),
        connectionId,
        catalog: catalog,
        schema: schema,
      ),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Returns catalog columns for [table] on [connectionId]. Binary result or
  /// `null` on error.
  Future<Uint8List?> catalogColumns(int connectionId, String table) async {
    final r = await _sendRequest<QueryResponse>(
      CatalogColumnsRequest(_nextRequestId(), connectionId, table),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Returns type info for [connectionId]. Binary result or `null` on error.
  Future<Uint8List?> catalogTypeInfo(int connectionId) async {
    final r = await _sendRequest<QueryResponse>(
      CatalogTypeInfoRequest(_nextRequestId(), connectionId),
    );
    if (r.error != null) return null;
    return r.data;
  }

  Future<Uint8List?> catalogPrimaryKeys(
    int connectionId,
    String table,
  ) async {
    final r = await _sendRequest<QueryResponse>(
      CatalogPrimaryKeysRequest(_nextRequestId(), connectionId, table),
    );
    if (r.error != null) return null;
    return r.data;
  }

  Future<Uint8List?> catalogForeignKeys(
    int connectionId,
    String table,
  ) async {
    final r = await _sendRequest<QueryResponse>(
      CatalogForeignKeysRequest(_nextRequestId(), connectionId, table),
    );
    if (r.error != null) return null;
    return r.data;
  }

  Future<Uint8List?> catalogIndexes(
    int connectionId,
    String table,
  ) async {
    final r = await _sendRequest<QueryResponse>(
      CatalogIndexesRequest(_nextRequestId(), connectionId, table),
    );
    if (r.error != null) return null;
    return r.data;
  }

  /// Creates a connection pool in the worker. Returns pool ID on success.
  Future<int> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) async {
    final r = await _sendRequest<IntResponse>(
      PoolCreateRequest(
        _nextRequestId(),
        connectionString,
        maxSize,
        optionsJson: options?.toJson(),
      ),
    );
    return r.value;
  }

  /// Obtains a connection from pool [poolId]. Returns connection ID on success.
  Future<int> poolGetConnection(int poolId) async {
    final r = await _sendRequest<IntResponse>(
      PoolGetConnectionRequest(_nextRequestId(), poolId),
    );
    return r.value;
  }

  /// Returns [connectionId] to its pool.
  Future<bool> poolReleaseConnection(int connectionId) async {
    final r = await _sendRequest<BoolResponse>(
      PoolReleaseConnectionRequest(_nextRequestId(), connectionId),
    );
    return r.value;
  }

  /// Runs a health check on pool [poolId].
  Future<bool> poolHealthCheck(int poolId) async {
    final r = await _sendRequest<BoolResponse>(
      PoolHealthCheckRequest(_nextRequestId(), poolId),
    );
    return r.value;
  }

  /// Returns the current state (size, idle) of pool [poolId],
  /// or `null` on error.
  Future<({int size, int idle})?> poolGetState(int poolId) async {
    final r = await _sendRequest<PoolStateResponse>(
      PoolGetStateRequest(_nextRequestId(), poolId),
    );
    if (r.error != null || r.size == null) return null;
    return (size: r.size!, idle: r.idle ?? 0);
  }

  /// Returns detailed pool state payload as JSON, or null on failure.
  Future<String?> poolGetStateJson(int poolId) async {
    final r = await _sendRequest<AuditPayloadResponse>(
      PoolGetStateJsonRequest(_nextRequestId(), poolId),
    );
    if (r.error != null) {
      return null;
    }
    return r.payload;
  }

  /// Resizes pool [poolId] to [newMaxSize] in the worker.
  Future<bool> poolSetSize(int poolId, int newMaxSize) async {
    final r = await _sendRequest<BoolResponse>(
      PoolSetSizeRequest(_nextRequestId(), poolId, newMaxSize),
    );
    return r.value;
  }

  /// Closes pool [poolId] in the worker.
  Future<bool> poolClose(int poolId) async {
    final r = await _sendRequest<BoolResponse>(
      PoolCloseRequest(_nextRequestId(), poolId),
    );
    return r.value;
  }

  /// Performs bulk insert on [connectionId]: [table], [columns], [dataBuffer],
  /// [rowCount]. Returns rows inserted, or negative on error.
  Future<int> bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) async {
    final r = await _sendRequest<IntResponse>(
      BulkInsertArrayRequest(
        _nextRequestId(),
        connectionId,
        table,
        columns,
        dataBuffer,
        rowCount,
      ),
    );
    return r.value;
  }

  /// Performs parallel bulk insert on [poolId]. Returns rows inserted,
  /// or negative value on error.
  Future<int> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int parallelism,
  ) async {
    final r = await _sendRequest<IntResponse>(
      BulkInsertParallelRequest(
        _nextRequestId(),
        poolId,
        table,
        columns,
        dataBuffer,
        parallelism,
      ),
    );
    return r.value;
  }

  /// Returns engine version (api + abi) for compatibility checks.
  Future<Map<String, String>?> getVersion() async {
    final r = await _sendRequest<VersionResponse>(
      GetVersionRequest(_nextRequestId()),
    );
    if (r.api.isEmpty && r.abi.isEmpty) return null;
    return {'api': r.api, 'abi': r.abi};
  }

  /// Returns ODBC metrics from the worker (query count, errors, latency, etc.).
  Future<OdbcMetrics?> getMetrics() async {
    final r = await _sendRequest<MetricsResponse>(
      GetMetricsRequest(_nextRequestId()),
    );
    if (r.error != null) return null;
    return OdbcMetrics(
      queryCount: r.queryCount,
      errorCount: r.errorCount,
      uptimeSecs: r.uptimeSecs,
      totalLatencyMillis: r.totalLatencyMillis,
      avgLatencyMillis: r.avgLatencyMillis,
    );
  }

  /// Returns prepared statement cache metrics from the worker.
  Future<PreparedStatementMetrics?> getCacheMetrics() async {
    final r = await _sendRequest<CacheMetricsResponse>(
      GetCacheMetricsRequest(_nextRequestId()),
    );
    if (r.error != null) return null;
    return PreparedStatementMetrics(
      cacheSize: r.cacheSize,
      cacheMaxSize: r.cacheMaxSize,
      cacheHits: r.cacheHits,
      cacheMisses: r.cacheMisses,
      totalPrepares: r.totalPrepares,
      totalExecutions: r.totalExecutions,
      memoryUsageBytes: r.memoryUsageBytes,
      avgExecutionsPerStmt: r.avgExecutionsPerStmt,
    );
  }

  /// Clears the prepared statement cache in the worker.
  Future<bool> clearStatementCache() async {
    final r = await _sendRequest<ClearCacheResponse>(
      ClearCacheRequest(_nextRequestId()),
    );
    return r.error == null;
  }

  /// Enables metadata cache in the worker.
  Future<bool> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) async {
    final r = await _sendRequest<BoolResponse>(
      MetadataCacheEnableRequest(
        _nextRequestId(),
        maxEntries: maxEntries,
        ttlSeconds: ttlSeconds,
      ),
    );
    return r.value;
  }

  /// Returns metadata cache stats as JSON payload, or null on failure.
  Future<String?> getMetadataCacheStatsJson() async {
    final r = await _sendRequest<AuditPayloadResponse>(
      MetadataCacheStatsRequest(_nextRequestId()),
    );
    if (r.error != null) {
      return null;
    }
    return r.payload;
  }

  /// Clears metadata cache entries in the worker.
  Future<bool> clearMetadataCache() async {
    final r = await _sendRequest<BoolResponse>(
      MetadataCacheClearRequest(_nextRequestId()),
    );
    return r.value;
  }

  Future<int> _streamStart(
    int connectionId,
    String sql, {
    int chunkSize = 1000,
  }) async {
    final r = await _sendRequest<IntResponse>(
      StreamStartRequest(
        _nextRequestId(),
        connectionId,
        sql,
        chunkSize: chunkSize,
      ),
    );
    return r.value;
  }

  Future<int> _streamStartBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async {
    final r = await _sendRequest<IntResponse>(
      StreamStartBatchedRequest(
        _nextRequestId(),
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      ),
    );
    return r.value;
  }

  Future<int> _streamStartAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async {
    final r = await _sendRequest<IntResponse>(
      StreamStartAsyncRequest(
        _nextRequestId(),
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      ),
    );
    return r.value;
  }

  /// Starts low-level async stream lifecycle and returns stream ID.
  Future<int> streamStartAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async {
    return _streamStartAsync(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    );
  }

  /// Starts a streaming multi-result batch (M8 in v3.3.0). The chunks
  /// emitted by `streamFetch` follow the framed wire format documented in
  /// `MultiResultStreamDecoder`. Returns 0 when the loaded native library
  /// does not export the FFI.
  Future<int> streamMultiStartBatched(
    int connectionId,
    String sql, {
    int chunkSize = 64 * 1024,
  }) async {
    final r = await _sendRequest<IntResponse>(
      StreamMultiStartBatchedRequest(
        _nextRequestId(),
        connectionId,
        sql,
        chunkSize: chunkSize,
      ),
    );
    return r.value;
  }

  /// Async variant of [streamMultiStartBatched]. Combine with
  /// `streamPollAsync`.
  Future<int> streamMultiStartAsync(
    int connectionId,
    String sql, {
    int chunkSize = 64 * 1024,
  }) async {
    final r = await _sendRequest<IntResponse>(
      StreamMultiStartAsyncRequest(
        _nextRequestId(),
        connectionId,
        sql,
        chunkSize: chunkSize,
      ),
    );
    return r.value;
  }

  Future<int> _streamPollAsync(int streamId) async {
    final r = await _sendRequest<IntResponse>(
      StreamPollAsyncRequest(_nextRequestId(), streamId),
    );
    return r.value;
  }

  /// Polls low-level async stream status.
  Future<int> streamPollAsync(int streamId) async {
    return _streamPollAsync(streamId);
  }

  Future<StreamFetchResponse> _streamFetch(int streamId) {
    return _sendRequest<StreamFetchResponse>(
      StreamFetchRequest(_nextRequestId(), streamId),
    );
  }

  /// Fetches the next chunk from an active stream in the worker.
  /// Public counterpart of `_streamFetch`, used by callers that drive the
  /// stream lifecycle themselves (e.g. `streamQueryMulti`). New in v3.3.0.
  Future<StreamFetchResponse> streamFetch(int streamId) =>
      _streamFetch(streamId);

  Future<bool> _streamClose(int streamId) async {
    final r = await _sendRequest<BoolResponse>(
      StreamCloseRequest(_nextRequestId(), streamId),
    );
    return r.value;
  }

  /// Closes an active stream in the worker. Public counterpart of
  /// `_streamClose` for the same reason as [streamFetch]. New in v3.3.0.
  Future<bool> streamClose(int streamId) => _streamClose(streamId);

  /// Cancels an active low-level native stream in the worker.
  Future<bool> streamCancel(int streamId) async {
    final r = await _sendRequest<BoolResponse>(
      StreamCancelRequest(_nextRequestId(), streamId),
    );
    return r.value;
  }

  /// Runs [sql] in the worker using native batched streaming.
  ///
  /// This path uses `odbc_stream_start_batched` + `odbc_stream_fetch`,
  /// yielding chunks progressively. [maxBufferBytes] caps internal pending
  /// bytes for message framing.
  Stream<ParsedRowBuffer> streamQueryBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int? maxBufferBytes,
  }) async* {
    final streamId = await _streamStartBatched(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    );
    if (streamId == 0) {
      final workerError = await _safeGetWorkerError();
      throw AsyncError(
        code: AsyncErrorCode.queryFailed,
        message: workerError ?? 'Failed to start batched stream',
      );
    }

    final pending = BinaryFrameAccumulator();
    final limit = maxBufferBytes;
    var completed = false;
    try {
      while (true) {
        final fetched = await _streamFetch(streamId);
        if (!fetched.success) {
          final workerError = fetched.error ?? await _safeGetWorkerError();
          throw AsyncError(
            code: AsyncErrorCode.queryFailed,
            message: workerError ?? 'Batched stream fetch failed',
          );
        }

        final data = fetched.data;
        if (data != null && data.isNotEmpty) {
          pending.add(data);
          if (limit != null && pending.length > limit) {
            throw const AsyncError(
              code: AsyncErrorCode.queryFailed,
              message: 'Streaming buffer exceeded maxBufferBytes',
            );
          }

          for (final msg in pending.drainFrames()) {
            yield BinaryProtocolParser.parse(msg);
          }
        }

        if (!fetched.hasMore) {
          break;
        }
      }

      if (pending.length > 0) {
        throw const FormatException(
          'Leftover bytes after stream; expected complete protocol messages',
        );
      }
      completed = true;
    } finally {
      if (!completed) {
        await streamCancel(streamId);
      }
      await _streamClose(streamId);
    }
  }

  /// Runs [sql] in the worker using native streaming.
  ///
  /// This path uses `odbc_stream_start` + `odbc_stream_fetch`. Data is
  /// accumulated and parsed at the end, matching sync `streamQuery` behavior.
  /// [maxBufferBytes] caps total accumulated bytes.
  Stream<ParsedRowBuffer> streamQuery(
    int connectionId,
    String sql, {
    int chunkSize = 1000,
    int? maxBufferBytes,
  }) async* {
    final streamId = await _streamStart(
      connectionId,
      sql,
      chunkSize: chunkSize,
    );
    if (streamId == 0) {
      final workerError = await _safeGetWorkerError();
      throw AsyncError(
        code: AsyncErrorCode.queryFailed,
        message: workerError ?? 'Failed to start stream',
      );
    }

    final buffer = BytesBuilder(copy: false);
    final limit = maxBufferBytes;
    var completed = false;
    try {
      while (true) {
        final fetched = await _streamFetch(streamId);
        if (!fetched.success) {
          final workerError = fetched.error ?? await _safeGetWorkerError();
          throw AsyncError(
            code: AsyncErrorCode.queryFailed,
            message: workerError ?? 'Stream fetch failed',
          );
        }

        final data = fetched.data;
        if (data != null && data.isNotEmpty) {
          buffer.add(data);
          if (limit != null && buffer.length > limit) {
            throw const AsyncError(
              code: AsyncErrorCode.queryFailed,
              message: 'Streaming buffer exceeded maxBufferBytes',
            );
          }
        }

        if (!fetched.hasMore) {
          break;
        }
      }

      if (buffer.length > 0) {
        yield BinaryProtocolParser.parse(buffer.toBytes());
      }
      completed = true;
    } finally {
      if (!completed) {
        await streamCancel(streamId);
      }
      await _streamClose(streamId);
    }
  }

  /// Runs [sql] using native async stream lifecycle:
  /// `stream_start_async -> stream_poll_async -> stream_fetch -> stream_close`.
  ///
  /// This is a poll-based non-blocking stream path. It yields full protocol
  /// messages as [ParsedRowBuffer] values.
  Stream<ParsedRowBuffer> streamAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    Duration pollInterval = const Duration(milliseconds: 10),
    int? maxBufferBytes,
  }) async* {
    final streamId = await _streamStartAsync(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    );
    if (streamId == 0) {
      final workerError = await _safeGetWorkerError();
      throw AsyncError(
        code: AsyncErrorCode.queryFailed,
        message: workerError ?? 'Failed to start async stream',
      );
    }

    final pending = BinaryFrameAccumulator();
    final limit = maxBufferBytes;
    var completed = false;
    try {
      while (true) {
        final status = await _streamPollAsync(streamId);
        if (status == _streamAsyncStatusPending) {
          await Future<void>.delayed(pollInterval);
          continue;
        }
        if (status == _streamAsyncStatusDone) {
          break;
        }
        if (status == _streamAsyncStatusError ||
            status == _streamAsyncStatusCancelled) {
          final workerError = await _safeGetWorkerError();
          throw AsyncError(
            code: AsyncErrorCode.queryFailed,
            message: workerError ?? 'Async stream failed with status $status',
          );
        }
        if (status != _streamAsyncStatusReady) {
          final workerError = await _safeGetWorkerError();
          throw AsyncError(
            code: AsyncErrorCode.queryFailed,
            message: workerError ?? 'Unexpected async stream status: $status',
          );
        }

        final fetched = await _streamFetch(streamId);
        if (!fetched.success) {
          final workerError = fetched.error ?? await _safeGetWorkerError();
          throw AsyncError(
            code: AsyncErrorCode.queryFailed,
            message: workerError ?? 'Async stream fetch failed',
          );
        }

        final data = fetched.data;
        if (data != null && data.isNotEmpty) {
          pending.add(data);
          if (limit != null && pending.length > limit) {
            throw const AsyncError(
              code: AsyncErrorCode.queryFailed,
              message: 'Streaming buffer exceeded maxBufferBytes',
            );
          }

          for (final msg in pending.drainFrames()) {
            yield BinaryProtocolParser.parse(msg);
          }
        }
      }

      if (pending.length > 0) {
        throw const FormatException(
          'Leftover bytes after stream; expected complete protocol messages',
        );
      }
      completed = true;
    } finally {
      if (!completed) {
        await streamCancel(streamId);
      }
      await _streamClose(streamId);
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
  /// Call when the async connection is no longer needed. After [dispose],
  /// [isInitialized] is false and [initialize] can be called again. In-flight
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
    _streamWorkerById.clear();
    _asyncRequestWorkerById.clear();
  }
}

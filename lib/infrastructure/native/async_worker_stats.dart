part of 'async_native_odbc_connection.dart';

mixin _AsyncWorkerStats on _AsyncOdbcState, _AsyncWorkerDispatch {
  /// Whether the worker isolate and ODBC environment are initialized.
  bool get isInitialized => _isInitialized;

  /// Returns a Dart-side snapshot of worker pool routing and health counters.
  AsyncWorkerPoolStats getWorkerPoolStats() {
    var activeRequests = 0;
    var pendingRequests = 0;
    var totalRouted = 0;
    var completedRequests = 0;
    var failedRequests = 0;
    var timeouts = 0;
    var fallbacksToBlocking = 0;
    var cancelAttempts = 0;
    var cancelSucceeded = 0;
    var cancelUnsupported = 0;
    var latencyTotalMicros = 0;
    var latencyMaxMicros = 0;
    var queueWaitTotalMicros = 0;
    var queueWaitMaxMicros = 0;
    var executionTotalMicros = 0;
    var executionMaxMicros = 0;
    final workers = List<AsyncWorkerStats>.generate(
      _workers.length,
      (index) {
        final worker = _workers[index];
        activeRequests += worker.activeRequests;
        pendingRequests += worker.pendingRequests.length;
        totalRouted += worker.totalRouted;
        completedRequests += worker.completedRequests;
        failedRequests += worker.failedRequests;
        timeouts += worker.timeouts;
        fallbacksToBlocking += worker.fallbacksToBlocking;
        cancelAttempts += worker.cancelAttempts;
        cancelSucceeded += worker.cancelSucceeded;
        cancelUnsupported += worker.cancelUnsupported;
        latencyTotalMicros += worker.latencyTotalMicros;
        if (worker.latencyMaxMicros > latencyMaxMicros) {
          latencyMaxMicros = worker.latencyMaxMicros;
        }
        queueWaitTotalMicros += worker.queueWaitTotalMicros;
        if (worker.queueWaitMaxMicros > queueWaitMaxMicros) {
          queueWaitMaxMicros = worker.queueWaitMaxMicros;
        }
        executionTotalMicros += worker.executionTotalMicros;
        if (worker.executionMaxMicros > executionMaxMicros) {
          executionMaxMicros = worker.executionMaxMicros;
        }
        return _statsForWorker(worker);
      },
      growable: false,
    );
    final completed = completedRequests + failedRequests;
    return AsyncWorkerPoolStats(
      workerCount: workerCount,
      activeRequests: activeRequests,
      pendingRequests: pendingRequests,
      totalRouted: totalRouted,
      completedRequests: completedRequests,
      failedRequests: failedRequests,
      timeouts: timeouts,
      fallbacksToBlocking: fallbacksToBlocking,
      cancelAttempts: cancelAttempts,
      cancelSucceeded: cancelSucceeded,
      cancelUnsupported: cancelUnsupported,
      latencyAvgMicros: completed == 0 ? 0 : latencyTotalMicros ~/ completed,
      latencyP95Micros: _aggregateP95(_WorkerMetricSample.latency),
      latencyMaxMicros: latencyMaxMicros,
      queueWaitAvgMicros:
          completed == 0 ? 0 : queueWaitTotalMicros ~/ completed,
      queueWaitP95Micros: _aggregateP95(_WorkerMetricSample.queueWait),
      queueWaitMaxMicros: queueWaitMaxMicros,
      executionAvgMicros:
          completed == 0 ? 0 : executionTotalMicros ~/ completed,
      executionP95Micros: _aggregateP95(_WorkerMetricSample.execution),
      executionMaxMicros: executionMaxMicros,
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

  // Delegates to the identical static implementation in _WorkerChannel.
  int _percentileLatency(Iterable<int> samples, int percentile) =>
      _WorkerChannel._percentile(samples, percentile);

  int get affinityEntryCountForTesting =>
      _connectionWorkerById.length +
      _statementWorkerById.length +
      _statementConnectionById.length +
      _transactionWorkerById.length +
      _xaWorkerById.length +
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
}

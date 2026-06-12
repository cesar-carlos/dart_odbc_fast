part of 'async_native_odbc_connection.dart';

mixin _AsyncWorkerStats on _AsyncOdbcState, _AsyncWorkerDispatch {
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

  // Delegates to the identical static implementation in _WorkerChannel.
  int _percentileLatency(Iterable<int> samples, int percentile) =>
      _WorkerChannel._percentile(samples, percentile);

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
}

/// Per-worker counters for the async ODBC worker pool.
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
/// Values are captured when worker-pool stats are queried and are maintained
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

part of 'async_native_odbc_connection.dart';

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

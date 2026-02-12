import 'dart:async';

import 'package:odbc_fast/domain/telemetry/entities.dart';

/// In-memory buffer for batching telemetry data before export.
///
/// This buffer accumulates telemetry data and flushes it periodically
/// to reduce FFI overhead and improve performance.
///
/// Features:
/// - Configurable batch size (number of items before auto-flush)
/// - Configurable flush interval (time-based auto-flush)
/// - Separate buffers for traces, spans, metrics, and events
class TelemetryBuffer {
  /// Creates a new telemetry buffer.
  ///
  /// [batchSize]: Number of items to accumulate before auto-flush
  /// [flushInterval]: Duration between automatic flushes
  TelemetryBuffer({
    int batchSize = 100,
    Duration flushInterval = const Duration(seconds: 30),
  })  : _batchSize = batchSize,
        _flushInterval = flushInterval {
    _startPeriodicFlush();
  }

  final int _batchSize;
  final Duration _flushInterval;
  void Function()? _onFlush;

  /// Sets the callback to be called when buffer flushes.
  void setOnFlush(void Function() callback) {
    _onFlush = callback;
  }

  List<Trace> _traces = [];
  List<Span> _spans = [];
  List<Metric> _metrics = [];
  List<TelemetryEvent> _events = [];

  Timer? _flushTimer;
  bool _isFlushing = false;

  /// Adds a trace to the buffer.
  ///
  /// Returns true if buffer should be flushed.
  bool addTrace(Trace trace) {
    _traces.add(trace);
    return _shouldFlush();
  }

  /// Adds a span to the buffer.
  ///
  /// Returns true if buffer should be flushed.
  bool addSpan(Span span) {
    _spans.add(span);
    return _shouldFlush();
  }

  /// Adds a metric to the buffer.
  ///
  /// Returns true if buffer should be flushed.
  bool addMetric(Metric metric) {
    _metrics.add(metric);
    return _shouldFlush();
  }

  /// Adds an event to the buffer.
  ///
  /// Returns true if buffer should be flushed.
  bool addEvent(TelemetryEvent event) {
    _events.add(event);
    return _shouldFlush();
  }

  /// Gets the current buffer size.
  int get size => _traces.length + _spans.length + _metrics.length + _events.length;

  /// Gets the number of traces in the buffer.
  int get traceCount => _traces.length;

  /// Gets the number of spans in the buffer.
  int get spanCount => _spans.length;

  /// Gets the number of metrics in the buffer.
  int get metricCount => _metrics.length;

  /// Gets the number of events in the buffer.
  int get eventCount => _events.length;

  /// Checks if buffer should be flushed based on size.
  bool _shouldFlush() {
    return size >= _batchSize;
  }

  /// Flushes all buffered telemetry data.
  ///
  /// Returns the flushed data and clears the buffer.
  TelemetryBatch flush() {
    if (_isFlushing || size == 0) {
      return TelemetryBatch.empty();
    }

    _isFlushing = true;

    try {
      final batch = TelemetryBatch(
        traces: List.from(_traces),
        spans: List.from(_spans),
        metrics: List.from(_metrics),
        events: List.from(_events),
      );

      _clear();

      return batch;
    } finally {
      _isFlushing = false;
    }
  }

  /// Clears all buffered data.
  void _clear() {
    _traces.clear();
    _spans.clear();
    _metrics.clear();
    _events.clear();
  }

  /// Starts the periodic flush timer.
  void _startPeriodicFlush() {
    _flushTimer = Timer.periodic(_flushInterval, (_) {
      if (size > 0) {
        flush();
        _onFlush?.call();
      }
    });
  }

  /// Stops the periodic flush timer.
  void stopPeriodicFlush() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  /// Disposes the buffer and stops periodic flushing.
  void dispose() {
    stopPeriodicFlush();
    _clear();
  }
}

/// Represents a batch of telemetry data to be exported.
class TelemetryBatch {

  /// Creates a new telemetry batch.
  TelemetryBatch({
    required this.traces,
    required this.spans,
    required this.metrics,
    required this.events,
  });
  /// Creates an empty telemetry batch.
  TelemetryBatch.empty()
      : traces = [],
        spans = [],
        metrics = [],
        events = [];

  /// Traces in this batch.
  final List<Trace> traces;

  /// Spans in this batch.
  final List<Span> spans;

  /// Metrics in this batch.
  final List<Metric> metrics;

  /// Events in this batch.
  final List<TelemetryEvent> events;

  /// Gets the total number of items in this batch.
  int get size => traces.length + spans.length + metrics.length + events.length;

  /// Checks if this batch is empty.
  bool get isEmpty =>
      traces.isEmpty && spans.isEmpty && metrics.isEmpty && events.isEmpty;
}

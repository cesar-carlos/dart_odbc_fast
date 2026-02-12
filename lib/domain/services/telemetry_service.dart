import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';

/// Interface for telemetry service.
///
/// Provides abstraction for telemetry operations to support
/// dependency inversion.
abstract class ITelemetryService {
  /// Service name for all traces.
  String get serviceName;

  /// Starts a new trace for an ODBC operation.
  ///
  /// The [operationName] should be descriptive (e.g., "odbc.query").
  /// Returns a [Trace] object that should be used to create child spans.
  Future<Trace> startTrace(String operationName);

  /// Finishes a trace by calculating duration.
  ///
  /// Call this when operation completes successfully.
  Future<void> endTrace({
    required String traceId,
    Map<String, String> attributes = const {},
  });

  /// Records a counter metric.
  ///
  /// Use for counting operations (e.g., query count, error count).
  Future<void> recordMetric({
    required String name,
    required String type, // "counter", "gauge", "histogram"
    required double value,
    String unit = 'count', // "ms", "bytes", etc.
    Map<String, String> attributes = const {},
  });

  /// Records a telemetry event (log entry).
  ///
  /// Use for significant events (errors, warnings, debug info).
  Future<void> recordEvent({
    required String name,
    required TelemetrySeverity severity,
    required String message,
    Map<String, dynamic> context = const {},
  });

  /// Flushes all pending telemetry data.
  ///
  /// Should be called before shutting down application.
  Future<void> flush();

  /// Shutdown telemetry exporter and release resources.
  ///
  /// Should be called when application is shutting down.
  Future<void> shutdown();
}

/// Service for managing OpenTelemetry-based tracing and metrics.
///
/// Provides a unified interface for instrumenting ODBC operations
/// with distributed tracing context.
///
/// Traces and spans are stored locally during operation and exported
/// only when ended (to calculate accurate duration).
class TelemetryService implements ITelemetryService {
  /// Creates a new [TelemetryService] instance.
  TelemetryService(this._repository);

  final ITelemetryRepository _repository;

  final Map<String, Trace> _activeTraces = {};
  final Map<String, Span> _activeSpans = {};

  @override
  String get serviceName => 'odbc_fast';

  /// Generates a unique trace ID.
  String _generateTraceId() {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final random = (timestamp * 1000 + (timestamp % 1000)).toRadixString(16);
    final unique = '$random-${_activeTraces.length}';
    return 'trace-$unique';
  }

  /// Generates a unique span ID.
  String _generateSpanId() {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final random = (timestamp * 1000 + (timestamp % 1000)).toRadixString(16);
    final unique = '$random-${_activeSpans.length}';
    return 'span-$unique';
  }

  /// Starts a new trace for an ODBC operation.
  ///
  /// The [operationName] should be descriptive (e.g., "odbc.query").
  /// Returns a [Trace] object that should be used to create child spans.
  @override
  Future<Trace> startTrace(String operationName) async {
    final traceId = _generateTraceId();
    final now = DateTime.now().toUtc();

    final trace = Trace(
      traceId: traceId,
      name: operationName,
      startTime: now,
      attributes: {},
    );

    _activeTraces[traceId] = trace;
    return trace;
  }

  /// Creates a child span within an existing trace.
  ///
  /// The [parentId] should be a traceId of the parent trace.
  /// The [spanName] should be descriptive (e.g., "query.execution").
  Future<Span> startSpan({
    required String parentId,
    required String spanName,
    Map<String, String> initialAttributes = const {},
  }) async {
    final spanId = _generateSpanId();
    final now = DateTime.now().toUtc();

    final span = Span(
      spanId: spanId,
      parentSpanId: parentId,
      traceId: parentId,
      name: spanName,
      startTime: now,
      attributes: initialAttributes,
    );

    _activeSpans[spanId] = span;
    return span;
  }

  /// Finishes a trace by calculating duration.
  ///
  /// Call this when operation completes successfully.
  @override
  Future<void> endTrace({
    required String traceId,
    Map<String, String> attributes = const {},
  }) async {
    final cached = _activeTraces[traceId];
    if (cached == null) {
      return;
    }

    final now = DateTime.now().toUtc();
    final duration = now.difference(cached.startTime);

    final updatedTrace = cached.copyWith(
      endTime: now,
      attributes: {...cached.attributes, ...attributes},
    );

    _repository.exportTrace(updatedTrace);
    _activeTraces.remove(traceId);
  }

  /// Finishes a span by calculating duration.
  ///
  /// Call this when a span completes successfully.
  Future<void> endSpan({
    required String spanId,
    Map<String, String> attributes = const {},
  }) async {
    final cached = _activeSpans[spanId];
    if (cached == null) {
      return;
    }

    final now = DateTime.now().toUtc();
    final duration = now.difference(cached.startTime);

    final updatedSpan = cached.copyWith(
      endTime: now,
      attributes: {...cached.attributes, ...attributes},
    );

    _repository.exportSpan(updatedSpan);
    _activeSpans.remove(spanId);
  }

  /// Records a counter metric.
  ///
  /// Use for counting operations (e.g., query count, error count).
  @override
  Future<void> recordMetric({
    required String name,
    required String type,
    required double value,
    String unit = 'count',
    Map<String, String> attributes = const {},
  }) async {
    final metric = Metric(
      name: name,
      value: value,
      unit: unit,
      timestamp: DateTime.now().toUtc(),
      attributes: attributes,
    );

    _repository.exportMetric(metric);
  }

  /// Records a gauge metric (current value).
  ///
  /// Use for measurements like pool size, active connections, etc.
  Future<void> recordGauge({
    required String name,
    required double value,
    Map<String, String> attributes = const {},
  }) async {
    await recordMetric(
      name: name,
      type: 'gauge',
      value: value,
      attributes: attributes,
    );
  }

  /// Records a timing metric.
  ///
  /// Use for measuring operation duration (e.g., query latency).
  Future<void> recordTiming({
    required String name,
    required Duration duration,
    Map<String, String> attributes = const {},
  }) async {
    await recordMetric(
      name: name,
      type: 'histogram',
      value: duration.inMilliseconds.toDouble(),
      unit: 'ms',
      attributes: attributes,
    );
  }

  /// Records a telemetry event (log entry).
  ///
  /// Use for significant events (errors, warnings, debug info).
  @override
  Future<void> recordEvent({
    required String name,
    required TelemetrySeverity severity,
    required String message,
    Map<String, dynamic> context = const {},
  }) async {
    final event = TelemetryEvent(
      name: name,
      severity: severity,
      message: message,
      timestamp: DateTime.now().toUtc(),
      context: context,
    );

    _repository.exportEvent(event);
  }

  /// Flushes all pending telemetry data.
  ///
  /// Should be called before shutting down application.
  @override
  Future<void> flush() async {
    _repository.flush();
  }

  /// Shutdown telemetry exporter and release resources.
  ///
  /// Should be called when application is shutting down.
  @override
  Future<void> shutdown() async {
    _repository.shutdown();
  }
}

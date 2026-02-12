import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:result_dart/result_dart.dart';

/// Simplified telemetry service for ODBC operations.
///
/// Provides methods for starting/ending traces, spans, and recording metrics.
/// Uses a simple [ITelemetryRepository] that doesn't return Result types.
class SimpleTelemetryService implements ITelemetryService {
  SimpleTelemetryService(this._repository);

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

  @override
  Trace startTrace(String operationName) {
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

  @override
  void endTrace({
    required String traceId,
    Map<String, String> attributes = const {},
  }) {
    final cached = _activeTraces[traceId];
    if (cached == null) {
      throw Exception('Trace $traceId not found');
    }

    final now = DateTime.now().toUtc();
    final duration = now.difference(cached.startTime);

    _repository.updateTrace(
      traceId: traceId,
      endTime: now,
      attributes: {...cached.attributes, ...attributes},
    );

    _activeTraces.remove(traceId);
  }

  @override
  Span startSpan({
    required String parentId,
    required String spanName,
    Map<String, String> initialAttributes = const {},
  }) {
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

  @override
  void endSpan({
    required String spanId,
    Map<String, String> attributes = const {},
  }) {
    final cached = _activeSpans[spanId];
    if (cached == null) {
      throw Exception('Span $spanId not found');
    }

    final now = DateTime.now().toUtc();
    final duration = now.difference(cached.startTime);

    _repository.updateSpan(
      spanId: spanId,
      endTime: now,
      attributes: {...cached.attributes, ...attributes},
    );

    _activeSpans.remove(spanId);
  }

  @override
  void recordMetric({
    required String name,
    required String metricType,
    required double value,
    String unit = 'count',
    Map<String, String> attributes = const {},
  }) {
    _repository.exportMetric(Metric(
      name: name,
      type: metricType,
      value: value,
      unit: unit,
      timestamp: DateTime.now().toUtc(),
      attributes: attributes,
    );
  }

  @override
  void recordGauge({
    required String name,
    required double value,
    Map<String, String> attributes = const {},
  }) {
    _repository.exportMetric(Metric(
      name: name,
      type: 'gauge',
      value: value,
      unit: 'count',
      timestamp: DateTime.now().toUtc(),
      attributes: attributes,
    );
  }

  @override
  void recordTiming({
    required String name,
    required Duration duration,
    Map<String, String> attributes = const {},
  }) {
    _repository.exportMetric(Metric(
      name: name,
      type: 'histogram',
      value: duration.inMilliseconds.toDouble(),
      unit: 'ms',
      timestamp: DateTime.now().toUtc(),
      attributes: attributes,
    );
  }

  @override
  void recordEvent({
    required String name,
    required TelemetrySeverity severity,
    required String message,
    Map<String, dynamic> context = const {},
  }) {
    _repository.exportEvent(TelemetryEvent(
      name: name,
      severity: severity,
      message: message,
      timestamp: DateTime.now().toUtc(),
      context: context,
    );
  }

  @override
  void flush() {
    _repository.flush();
  }

  @override
  void shutdown() {
    _repository.shutdown();
  }
}

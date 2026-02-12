import 'package:odbc_fast/domain/errors/telemetry_error.dart';
import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:result_dart/result_dart.dart';

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
  /// Returns [ResultDart] with trace on success or [TelemetryException] on error.
  Future<ResultDart<Trace, TelemetryException>> startTrace(String operationName);

  /// Finishes a trace by calculating duration.
  ///
  /// Call this when operation completes successfully.
  /// Returns [ResultDart] with success or [TelemetryException].
  Future<ResultDart<void, TelemetryException>> endTrace({
    required String traceId,
    Map<String, String> attributes = const {},
  });

  /// Creates a child span within an existing trace.
  ///
  /// The [parentId] should be a traceId of parent trace.
  /// The [spanName] should be descriptive (e.g., "query.execution").
  /// Returns [ResultDart] with span on success or [TelemetryException] on error.
  Future<ResultDart<Span, TelemetryException>> startSpan({
    required String parentId,
    required String spanName,
    Map<String, String> initialAttributes = const {},
  });

  /// Finishes a span by calculating duration.
  ///
  /// Call this when span completes successfully.
  /// Returns [ResultDart] with success or [TelemetryException].
  Future<ResultDart<void, TelemetryException>> endSpan({
    required String spanId,
    Map<String, String> attributes = const {},
  });

  /// Records a counter metric.
  ///
  /// Use for counting operations (e.g., query count, error count).
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  Future<ResultDart<void, TelemetryException>> recordMetric({
    required String name,
    required String metricType,
    required double value,
    String unit = 'count',
    Map<String, String> attributes = const {},
  });

  /// Records a gauge metric (current value).
  ///
  /// Use for measurements like pool size, active connections, etc.
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  Future<ResultDart<void, TelemetryException>> recordGauge({
    required String name,
    required double value,
    Map<String, String> attributes = const {},
  });

  /// Records a timing metric.
  ///
  /// Use for measuring operation duration (e.g., query latency).
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  Future<ResultDart<void, TelemetryException>> recordTiming({
    required String name,
    required Duration duration,
    Map<String, String> attributes = const {},
  });

  /// Records a telemetry event (log entry).
  ///
  /// Use for significant events (errors, warnings, debug info).
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  Future<ResultDart<void, TelemetryException>> recordEvent({
    required String name,
    required TelemetrySeverity severity,
    required String message,
    Map<String, dynamic> context = const {},
  });

  /// Flushes all pending telemetry data.
  ///
  /// Should be called before shutting down application.
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  Future<ResultDart<void, TelemetryException>> flush();

  /// Shutdown telemetry exporter and release resources.
  ///
  /// Should be called when application is shutting down.
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  Future<ResultDart<void, TelemetryException>> shutdown();
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
  /// Returns [ResultDart] with trace on success or [TelemetryException] on error.
  @override
  Future<ResultDart<Trace, TelemetryException>> startTrace(String operationName) async {
    final traceId = _generateTraceId();
    final now = DateTime.now().toUtc();

    final trace = Trace(
      traceId: traceId,
      name: operationName,
      startTime: now,
      attributes: {},
    );

    _activeTraces[traceId] = trace;
    return Success(trace);
  }

  /// Finishes a trace by calculating duration.
  ///
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  @override
  Future<ResultDart<void, TelemetryException>> endTrace({
    required String traceId,
    Map<String, String> attributes = const {},
  }) async {
    final cached = _activeTraces[traceId];
    if (cached == null) {
      return Failure(
        TelemetryException(
          message: 'Trace $traceId not found',
          code: 'TRACE_NOT_FOUND',
        ),
      );
    }

    final now = DateTime.now().toUtc();
    final duration = now.difference(cached.startTime);
    final updatedTrace = cached.copyWith(
      endTime: now,
      attributes: {...cached.attributes, ...attributes},
    );

    final result = await _repository.updateTrace(
      traceId: traceId,
      endTime: now,
      attributes: updatedTrace.attributes,
    );

    return result.fold(
      (error) => Failure(error),
      (success) {
        _activeTraces.remove(traceId);
        return const Success(null);
      },
    );
  }

  /// Creates a child span within an existing trace.
  ///
  /// Returns [ResultDart] with span on success or [TelemetryException] on error.
  @override
  Future<ResultDart<Span, TelemetryException>> startSpan({
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
    return Success(span);
  }

  /// Finishes a span by calculating duration.
  ///
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  @override
  Future<ResultDart<void, TelemetryException>> endSpan({
    required String spanId,
    Map<String, String> attributes = const {},
  }) async {
    final cached = _activeSpans[spanId];
    if (cached == null) {
      return Failure(
        TelemetryException(
          message: 'Span $spanId not found',
          code: 'SPAN_NOT_FOUND',
        ),
      );
    }

    final now = DateTime.now().toUtc();
    final duration = now.difference(cached.startTime);
    final updatedSpan = cached.copyWith(
      endTime: now,
      attributes: {...cached.attributes, ...attributes},
    );

    final result = await _repository.updateSpan(
      spanId: spanId,
      endTime: now,
      attributes: updatedSpan.attributes,
    );

    return result.fold(
      (error) => Failure(error),
      (success) {
        _activeSpans.remove(spanId);
        return const Success(null);
      },
    );
  }

  /// Records a counter metric.
  ///
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  @override
  Future<ResultDart<void, TelemetryException>> recordMetric({
    required String name,
    required String metricType,
    required double value,
    String unit = 'count',
    Map<String, String> attributes = const {},
  }) async {
    final metric = Metric(
      name: name,
      type: metricType,
      value: value,
      unit: unit,
      timestamp: DateTime.now().toUtc(),
      attributes: attributes,
    );

    final result = await _repository.exportMetric(metric);
    return result.fold(
      (error) => Failure(error),
      (_) => const Success(null),
    );
  }

  /// Records a gauge metric (current value).
  ///
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  @override
  Future<ResultDart<void, TelemetryException>> recordGauge({
    required String name,
    required double value,
    Map<String, String> attributes = const {},
  }) async {
    final metric = Metric(
      name: name,
      type: 'gauge',
      value: value,
      unit: 'count',
      timestamp: DateTime.now().toUtc(),
      attributes: attributes,
    );

    final result = await _repository.exportMetric(metric);
    return result.fold(
      (error) => Failure(error),
      (_) => const Success(null),
    );
  }

  /// Records a timing metric.
  ///
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  @override
  Future<ResultDart<void, TelemetryException>> recordTiming({
    required String name,
    required Duration duration,
    Map<String, String> attributes = const {},
  }) async {
    final metric = Metric(
      name: name,
      type: 'histogram',
      value: duration.inMilliseconds.toDouble(),
      unit: 'ms',
      timestamp: DateTime.now().toUtc(),
      attributes: attributes,
    );

    final result = await _repository.exportMetric(metric);
    return result.fold(
      (error) => Failure(error),
      (_) => const Success(null),
    );
  }

  /// Records a telemetry event (log entry).
  ///
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  @override
  Future<ResultDart<void, TelemetryException>> recordEvent({
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

    final result = await _repository.exportEvent(event);
    return result.fold(
      (error) => Failure(error),
      (_) => const Success(null),
    );
  }

  /// Flushes all pending telemetry data.
  ///
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  @override
  Future<ResultDart<void, TelemetryException>> flush() async {
    final result = await _repository.flush();
    return result.fold(
      (error) => Failure(error),
      (_) => const Success(null),
    );
  }

  /// Shutdown telemetry exporter and release resources.
  ///
  /// Returns [ResultDart] with success or [TelemetryException] on error.
  @override
  Future<ResultDart<void, TelemetryException>> shutdown() async {
    final result = await _repository.shutdown();
    return result.fold(
      (error) => Failure(error),
      (_) => const Success(null),
    );
  }
}

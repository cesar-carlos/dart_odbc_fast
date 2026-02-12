import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';

/// Simplified interface for telemetry service operations.
///
/// Methods return values directly instead of Result types.
/// This makes the service easier to use and test.
abstract class ITelemetryService {
  /// Service name for all traces.
  String get serviceName;

  /// Starts a new trace for an ODBC operation.
  ///
  /// The [operationName] should be descriptive (e.g., "odbc.query").
  /// Returns a [Trace] object that should be used to create child spans.
  Trace startTrace(String operationName);

  /// Finishes a trace by calculating duration.
  ///
  /// Call this when operation completes successfully.
  Future<void> endTrace({
    required String traceId,
    Map<String, String> attributes = const {},
  });

  /// Creates a child span within an existing trace.
  ///
  /// The [parentId] should be a traceId of parent trace.
  /// The [spanName] should be descriptive (e.g., "query.execution").
  /// Returns a [Span] object.
  Span startSpan({
    required String parentId,
    required String spanName,
    Map<String, String> initialAttributes = const {},
  });

  /// Finishes a span by calculating duration.
  ///
  /// Call this when a span completes successfully.
  Future<void> endSpan({
    required String spanId,
    Map<String, String> attributes = const {},
  });

  /// Records a counter metric.
  ///
  /// Use for counting operations (e.g., query count, error count).
  Future<void> recordMetric({
    required String name,
    required String metricType,
    required double value,
    String unit = 'count',
    Map<String, String> attributes = const {},
  });

  /// Records a gauge metric (current value).
  ///
  /// Use for measurements like pool size, active connections, etc.
  Future<void> recordGauge({
    required String name,
    required double value,
    Map<String, String> attributes = const {},
  });

  /// Records a timing metric.
  ///
  /// Use for measuring operation duration (e.g., query latency).
  Future<void> recordTiming({
    required String name,
    required Duration duration,
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

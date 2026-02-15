import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:odbc_fast/odbc_fast.dart'
    show SimpleTelemetryService, TelemetryException;

/// Simplified interface for telemetry service operations.
///
/// Provides methods for starting/ending traces, spans, and recording metrics.
/// Methods return [Future<void>] for async operations that interact with
/// the repository.
///
/// ## Architecture
///
/// This service follows the Clean Architecture pattern:
/// - **Domain Layer**: Defines [ITelemetryService] and [TelemetryException]
/// - **Application Layer**: [SimpleTelemetryService] implements the interface
/// - **Infrastructure Layer**: [ITelemetryRepository] defines repository
///   interface
///
/// ## Usage Example
///
/// ```dart
/// final telemetry = SimpleTelemetryService(mockRepository);
///
/// // Start a trace for database operation
/// final trace = telemetry.startTrace('database.query');
///
/// // Execute query and record metrics
/// await telemetry.recordMetric(
///   name: 'query.count',
///   metricType: 'counter',
///   value: 1,
/// );
///
/// // End trace when operation completes
/// await telemetry.endTrace(traceId: trace.traceId);
/// ```
///
/// ## Thread Safety
///
/// **IMPORTANT**: [Trace] and [Span] returned by [startTrace]/[startSpan]
/// are NOT thread-safe. Do NOT share across isolates.
/// Always create new Trace/Span objects within the same isolate that needs them.
///
/// ## Key Features
///
/// - **Tracing**: Distributed tracing with parent-child relationships
/// - **Metrics**: Counters, gauges, and histograms
/// - **Events**: Log entries with severity levels
/// - **Auto-batching**: Automatic buffer flushing at intervals
/// - **Error Handling**: Repository handles errors internally; service does
///   not need to catch
abstract class ITelemetryService {
  /// Service name identifier.
  ///
  /// Used in all trace data as the service name.
  String get serviceName;

  /// Starts a new distributed trace.
  ///
  /// The [operationName] should describe the operation (e.g., "odbc.query").
  /// Returns a [Trace] object containing trace ID and start time.
  ///
  /// **Thread Safety**: The returned [Trace] object is not thread-safe.
  /// Do NOT share across isolates. Use within the creating isolate only.
  Trace startTrace(String operationName);

  /// Finishes a trace with optional attributes.
  ///
  /// Call this when the operation completes successfully.
  /// The [traceId] must match a previously started trace.
  /// Additional [attributes] can be attached for filtering.
  ///
  /// Returns [Future<void>] to allow for async repository operations.
  Future<void> endTrace({
    required String traceId,
    Map<String, String> attributes = const {},
  });

  /// Creates a child span within a trace.
  ///
  /// The [parentId] should be a trace ID from [startTrace].
  /// The [spanName] should describe the sub-operation
  /// (e.g., "query.execution").
  /// Returns a [Span] object containing span ID.
  ///
  /// **Thread Safety**: The returned [Span] object is not thread-safe.
  /// Do NOT share across isolates.
  Span startSpan({
    required String parentId,
    required String spanName,
    Map<String, String> initialAttributes = const {},
  });

  /// Finishes a span with optional attributes.
  ///
  /// Call this when the sub-operation completes.
  /// The [spanId] must match a previously created span.
  ///
  /// Returns [Future<void>] to allow for async repository operations.
  Future<void> endSpan({
    required String spanId,
    Map<String, String> attributes = const {},
  });

  /// Records a counter metric.
  ///
  /// The [metricType] specifies the metric kind (e.g., "counter").
  /// Returns [Future<void>] to allow for async repository operations.
  Future<void> recordMetric({
    required String name,
    required String metricType,
    required double value,
    String unit = 'count',
    Map<String, String> attributes = const {},
  });

  /// Records a gauge metric (current value).
  ///
  /// Use for measurements like pool size, active connections.
  /// Returns [Future<void>] to allow for async repository operations.
  Future<void> recordGauge({
    required String name,
    required double value,
    Map<String, String> attributes = const {},
  });

  /// Records a timing metric.
  ///
  /// Use for measuring operation duration (e.g., query latency).
  /// Duration is automatically converted to milliseconds.
  /// Returns [Future<void>] to allow for async repository operations.
  Future<void> recordTiming({
    required String name,
    required Duration duration,
    Map<String, String> attributes = const {},
  });

  /// Records a telemetry event (log entry).
  ///
  /// Use for significant events (errors, warnings, debug info).
  /// Returns [Future<void>] to allow for async repository operations.
  Future<void> recordEvent({
    required String name,
    required TelemetrySeverity severity,
    required String message,
    Map<String, dynamic> context = const {},
  });

  /// Flushes all pending telemetry data.
  ///
  /// Should be called before shutting down application.
  /// Returns [Future<void>] to allow for async repository operations.
  Future<void> flush();

  /// Shutdowns telemetry exporter and releases resources.
  ///
  /// Should be called when application is shutting down.
  /// Returns [Future<void>] to allow for async repository operations.
  Future<void> shutdown();
}

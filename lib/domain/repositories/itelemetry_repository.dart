import 'package:odbc_fast/domain/telemetry/entities.dart';

/// Repository interface for telemetry operations.
///
/// Provides methods for exporting traces, metrics, and events.
/// Implementations can send data to OpenTelemetry, console, or custom backends.
/// Methods return `Future<void>` to simplify error handling; errors are handled
/// internally.
abstract class ITelemetryRepository {
  /// Export a trace to telemetry backend.
  ///
  /// The [trace] will be queued and sent asynchronously.
  Future<void> exportTrace(Trace trace);

  /// Export a span to telemetry backend.
  ///
  /// The [span] will be queued and sent asynchronously.
  Future<void> exportSpan(Span span);

  /// Export a metric to telemetry backend.
  ///
  /// The [metric] will be queued and sent asynchronously.
  Future<void> exportMetric(Metric metric);

  /// Export an event to telemetry backend.
  ///
  /// The [event] will be queued and sent asynchronously.
  Future<void> exportEvent(TelemetryEvent event);

  /// Update an existing trace with new end time and attributes.
  ///
  /// Used when a trace is completed to calculate final duration.
  Future<void> updateTrace({
    required String traceId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  });

  /// Update an existing span with new end time and attributes.
  ///
  /// Used when a span is completed to calculate final duration.
  Future<void> updateSpan({
    required String spanId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  });

  /// Flush any buffered telemetry data.
  ///
  /// Should be called before shutting down application.
  Future<void> flush();

  /// Shutdown telemetry exporter and release resources.
  ///
  /// Should be called when application is shutting down.
  Future<void> shutdown();
}

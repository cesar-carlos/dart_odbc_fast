import 'package:odbc_fast/domain/telemetry/entities.dart';

/// Repository interface for telemetry operations.
///
/// Provides methods for exporting traces, metrics, and events.
/// Implementations can send data to OpenTelemetry, console, or custom backends.
abstract class ITelemetryRepository {
  /// Initialize telemetry backend.
  ///
  /// The [otlpEndpoint] specifies the OTLP collector URL.
  /// Returns true if initialization was successful.
  bool initialize({String otlpEndpoint = 'http://localhost:4318'});

  /// Export a trace to telemetry backend.
  ///
  /// The [trace] will be queued and sent asynchronously.
  void exportTrace(Trace trace);

  /// Export a span to telemetry backend.
  ///
  /// The [span] will be queued and sent asynchronously.
  void exportSpan(Span span);

  /// Export a metric to telemetry backend.
  ///
  /// The [metric] will be queued and sent asynchronously.
  void exportMetric(Metric metric);

  /// Export an event to telemetry backend.
  ///
  /// The [event] will be queued and sent asynchronously.
  void exportEvent(TelemetryEvent event);

  /// Update an existing trace with new end time and attributes.
  ///
  /// Used when a trace is completed to calculate final duration.
  void updateTrace({
    required String traceId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  });

  /// Update an existing span with new end time and attributes.
  ///
  /// Used when a span is completed to calculate final duration.
  void updateSpan({
    required String spanId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  });

  /// Flush any buffered telemetry data.
  ///
  /// Should be called before shutting down application.
  void flush();

  /// Shutdown telemetry exporter and release resources.
  ///
  /// Should be called when application is shutting down.
  void shutdown();
}

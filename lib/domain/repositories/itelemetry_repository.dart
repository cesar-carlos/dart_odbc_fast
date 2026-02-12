import 'package:odbc_fast/domain/errors/telemetry_error.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:result_dart/result_dart.dart';

/// Repository interface for telemetry operations.
///
/// Provides methods for exporting traces, metrics, and events.
/// Implementations can send data to OpenTelemetry, console, or custom backends.
/// Returns [ResultDart] types for error handling instead of throwing exceptions.
abstract class ITelemetryRepository {
  /// Initialize telemetry backend.
  ///
  /// The [otlpEndpoint] specifies the OTLP collector URL.
  /// Returns [ResultDart] with success or [TelemetryException].
  Future<ResultDart<void, TelemetryException>> initialize({
    String otlpEndpoint = 'http://localhost:4318',
  });

  /// Export a trace to telemetry backend.
  ///
  /// The [trace] will be queued and sent asynchronously.
  /// Returns [ResultDart] with success or [TelemetryException].
  Future<ResultDart<void, TelemetryException>> exportTrace(Trace trace);

  /// Export a span to telemetry backend.
  ///
  /// The [span] will be queued and sent asynchronously.
  /// Returns [ResultDart] with success or [TelemetryException].
  Future<ResultDart<void, TelemetryException>> exportSpan(Span span);

  /// Export a metric to telemetry backend.
  ///
  /// The [metric] will be queued and sent asynchronously.
  /// Returns [ResultDart] with success or [TelemetryException].
  Future<ResultDart<void, TelemetryException>> exportMetric(Metric metric);

  /// Export an event to telemetry backend.
  ///
  /// The [event] will be queued and sent asynchronously.
  /// Returns [ResultDart] with success or [TelemetryException].
  Future<ResultDart<void, TelemetryException>> exportEvent(TelemetryEvent event);

  /// Update an existing trace with new end time and attributes.
  ///
  /// Used when a trace is completed to calculate final duration.
  /// Returns [ResultDart] with success or [TelemetryException].
  Future<ResultDart<void, TelemetryException>> updateTrace({
    required String traceId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  });

  /// Update an existing span with new end time and attributes.
  ///
  /// Used when a span is completed to calculate final duration.
  /// Returns [ResultDart] with success or [TelemetryException].
  Future<ResultDart<void, TelemetryException>> updateSpan({
    required String spanId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  });

  /// Flush any buffered telemetry data.
  ///
  /// Should be called before shutting down application.
  /// Returns [ResultDart] with success or [TelemetryException].
  Future<ResultDart<void, TelemetryException>> flush();

  /// Shutdown telemetry exporter and release resources.
  ///
  /// Should be called when application is shutting down.
  /// Returns [ResultDart] with success or [TelemetryException].
  Future<ResultDart<void, TelemetryException>> shutdown();
}

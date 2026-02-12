/// Simplified OpenTelemetry FFI stub for testing.
///
/// This is a minimal stub that compiles without errors.
/// In production, this would bind to native OpenTelemetry library.
class OpenTelemetryFFI {
  /// Creates a new instance (stub).
  factory OpenTelemetryFFI() => OpenTelemetryFFI._();

  OpenTelemetryFFI._();

  /// Stub initialize - always returns success (1).
  int initialize(String otlpEndpoint) => 1;

  /// Stub export methods - do nothing and return success.
  int exportTrace(String traceJson) => 1;
  int exportSpan(String spanJson) => 1;
  int exportMetric(String metricJson) => 1;
  int exportEvent(String eventJson) => 1;
  int updateTrace(String traceId, String endTime, String attributesJson) => 1;
  int updateSpan(String spanId, String endTime, String attributesJson) => 1;
  int flush() => 1;
  int shutdown() => 1;
}

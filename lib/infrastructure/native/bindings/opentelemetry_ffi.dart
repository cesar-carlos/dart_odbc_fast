/// Simplified OpenTelemetry FFI stub for testing.
///
/// This is a minimal stub that compiles without errors.
/// In production, this would bind to native OpenTelemetry library.
class OpenTelemetryFFI {
  OpenTelemetryFFI() : this._();

  OpenTelemetryFFI._();

  bool _initialized = false;

  /// Stub initialize - always returns success (1).
  int initialize([String otlpEndpoint = '']) {
    _initialized = true;
    return 1;
  }

  /// Stub export methods - do nothing and return success.
  /// Throws if not initialized (for test coverage).
  int exportTrace(String traceJson) {
    if (!_initialized) throw Exception('Not initialized');
    return 1;
  }

  int exportTraceToString(String input) {
    if (!_initialized) throw Exception('Not initialized');
    return 1;
  }

  int exportSpan(String spanJson) => 1;
  int exportMetric(String metricJson) => 1;
  int exportEvent(String eventJson) => 1;
  int updateTrace(String traceId, String endTime, String attributesJson) => 1;
  int updateSpan(String spanId, String endTime, String attributesJson) => 1;
  int flush() => 1;

  int shutdown() => 1;

  /// Stub - returns empty string when no error.
  String getLastErrorMessage() => '';
}

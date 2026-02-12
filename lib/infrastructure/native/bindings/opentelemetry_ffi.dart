import 'dart:typed_data';

/// Simplified OpenTelemetry FFI stub for testing.
///
/// This is a minimal stub that compiles without errors.
class OpenTelemetryFFI {
  /// Creates a new instance (stub).
  factory OpenTelemetryFFI() => OpenTelemetryFFI._();

  /// Stub initialize - always succeeds.
  external int initialize(
    Pointer<Utf8> otlpEndpoint,
  );

  /// Stub export methods - do nothing.
  external int exportTrace(Pointer<Utf8> traceJson);
  external int exportSpan(Pointer<Utf8> spanJson);
  external int exportMetric(Pointer<Utf8> metricJson);
  external int exportEvent(Pointer<Utf8> eventJson);
  external int updateTrace(Pointer<Utf8> traceId, Pointer<Utf8> endTime, Pointer<Utf8> attributesJson);
  external int updateSpan(Pointer<Utf8> spanId, Pointer<Utf8> endTime, Pointer<Utf8> attributesJson);
  external int flush(Pointer<Int8> outFlushedCount);
  external int shutdown();
}

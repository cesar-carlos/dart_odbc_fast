/// Domain errors for telemetry operations.
///
/// Provides structured error types for telemetry failures
/// with recovery mechanisms and detailed context.

library;

/// Base exception for all telemetry errors.
class TelemetryException implements Exception {
  const TelemetryException({
    required this.message,
    this.code = 'UNKNOWN',
    this.timestamp,
    this.stackTrace,
  });

  /// Creates a [TelemetryException] with current timestamp.
  factory TelemetryException.now({
    required String message,
    String code = 'UNKNOWN',
    dynamic stackTrace,
  }) =>
      TelemetryException(
        message: message,
        code: code,
        timestamp: DateTime.now(),
        stackTrace: stackTrace,
      );

  /// Human-readable description of the error.
  final String message;

  /// Error code for programmatic handling.
  final String code;

  /// Optional timestamp when error occurred.
  final DateTime? timestamp;

  /// Optional stack trace for debugging.
  final dynamic stackTrace;

  @override
  String toString() =>
      'TelemetryException[$code]: $message${timestamp != null ? ' at ${timestamp!.toIso8601String()}' : ''}${stackTrace != null ? '\n$stackTrace' : ''}';
}

/// Error when telemetry initialization fails.
class TelemetryInitializationException extends TelemetryException {
  const TelemetryInitializationException({
    required super.message,
    super.code = 'INIT_FAILED',
    super.stackTrace,
  });
}

/// Error when telemetry export fails.
class TelemetryExportException extends TelemetryException {
  const TelemetryExportException({
    required super.message,
    super.code = 'EXPORT_FAILED',
    this.attemptNumber,
    super.stackTrace,
  });
  final int? attemptNumber;
}

/// Error when telemetry buffer operations fail.
class TelemetryBufferException extends TelemetryException {
  const TelemetryBufferException({
    required super.message,
    super.code = 'BUFFER_ERROR',
    this.bufferSize,
    super.stackTrace,
  });
  final int? bufferSize;
}

/// Error when telemetry shutdown fails.
class TelemetryShutdownException extends TelemetryException {
  const TelemetryShutdownException({
    required super.message,
    super.code = 'SHUTDOWN_FAILED',
    super.stackTrace,
  });
}

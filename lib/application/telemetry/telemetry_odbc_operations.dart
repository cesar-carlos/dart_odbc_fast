import 'package:odbc_fast/domain/services/simple_telemetry_service.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart'
    show TelemetrySeverity;

/// Shared telemetry helpers for ODBC capability decorators.
class TelemetryOdbcOperations {
  /// Creates operations bound to the supplied telemetry service.
  TelemetryOdbcOperations(this._telemetry);

  final SimpleTelemetryService _telemetry;

  /// Wraps an ODBC call in a telemetry span.
  Future<T> inOperation<T>(
    String name,
    Future<T> Function() operation,
  ) =>
      _telemetry.inOperation(name, operation);

  /// Wraps a stream-returning ODBC call with open/close telemetry events.
  ///
  /// Per-chunk events are intentionally omitted to avoid amplification on
  /// large result sets.
  Stream<T> wrapStream<T>(
    String operation,
    Stream<T> Function() factory,
  ) async* {
    final start = DateTime.now();
    var chunkCount = 0;
    await _telemetry.recordEvent(
      name: '$operation.open',
      severity: TelemetrySeverity.info,
      message: 'stream subscription opened',
      context: {'operation': operation},
    );
    try {
      await for (final chunk in factory()) {
        chunkCount++;
        yield chunk;
      }
      await _telemetry.recordEvent(
        name: '$operation.close',
        severity: TelemetrySeverity.info,
        message: 'stream completed normally',
        context: {
          'operation': operation,
          'chunkCount': chunkCount,
          'durationMs': DateTime.now().difference(start).inMilliseconds,
        },
      );
    } on Object catch (e) {
      await _telemetry.recordEvent(
        name: '$operation.error',
        severity: TelemetrySeverity.error,
        message: 'stream failed: $e',
        context: {
          'operation': operation,
          'chunkCount': chunkCount,
          'durationMs': DateTime.now().difference(start).inMilliseconds,
        },
      );
      rethrow;
    }
  }
}

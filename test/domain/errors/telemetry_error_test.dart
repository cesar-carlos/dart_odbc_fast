import 'package:odbc_fast/domain/errors/telemetry_error.dart';
import 'package:test/test.dart';

void main() {
  group('TelemetryException', () {
    test('toString includes code and message', () {
      const error = TelemetryException(
        message: 'export failed',
        code: 'EXPORT',
      );

      expect(error.toString(), 'TelemetryException[EXPORT]: export failed');
    });

    test('toString includes timestamp and stack trace when present', () {
      final timestamp = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final error = TelemetryException(
        message: 'init failed',
        code: 'INIT',
        timestamp: timestamp,
        stackTrace: 'stack',
      );

      expect(error.toString(), contains(timestamp.toIso8601String()));
      expect(error.toString(), contains('stack'));
    });

    test('now stamps current time and custom code', () {
      final before = DateTime.now();
      final error = TelemetryException.now(
        message: 'buffer full',
        code: 'BUFFER',
      );
      final after = DateTime.now();

      expect(error.message, 'buffer full');
      expect(error.code, 'BUFFER');
      expect(error.timestamp, isNotNull);
      expect(error.timestamp!.isBefore(before), isFalse);
      expect(error.timestamp!.isAfter(after), isFalse);
    });
  });

  group('specialized telemetry exceptions', () {
    test('expose default codes and extra fields', () {
      const init = TelemetryInitializationException(message: 'init');
      const export = TelemetryExportException(
        message: 'export',
        attemptNumber: 2,
      );
      const buffer = TelemetryBufferException(
        message: 'buffer',
        bufferSize: 10,
      );
      const shutdown = TelemetryShutdownException(message: 'shutdown');

      expect(init.code, 'INIT_FAILED');
      expect(export.code, 'EXPORT_FAILED');
      expect(export.attemptNumber, 2);
      expect(buffer.code, 'BUFFER_ERROR');
      expect(buffer.bufferSize, 10);
      expect(shutdown.code, 'SHUTDOWN_FAILED');
    });
  });
}

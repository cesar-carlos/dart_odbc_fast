import 'package:odbc_fast/infrastructure/native/audit/async_odbc_audit_logger.dart';
import 'package:test/test.dart';

void main() {
  group('AsyncOdbcAuditLogger', () {
    test('getStatus parses payload', () async {
      final logger = AsyncOdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) async => true,
        clear: () async => true,
        getEventsJson: ({limit = 0}) async => '[]',
        getStatusJson: () async => '{"enabled":true,"event_count":3}',
      );

      final status = await logger.getStatus();

      expect(status, isNotNull);
      expect(status!.enabled, isTrue);
      expect(status.eventCount, 3);
    });

    test('getEvents parses payload list', () async {
      final logger = AsyncOdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) async => true,
        clear: () async => true,
        getEventsJson: ({limit = 0}) async =>
            '[{"timestamp_ms":1,"event_type":"query","connection_id":7,'
            '"query":"SELECT 1","metadata":{"k":"v"}}]',
        getStatusJson: () async => '{"enabled":true,"event_count":1}',
      );

      final events = await logger.getEvents(limit: 10);

      expect(events.length, 1);
      expect(events.first.eventType, 'query');
      expect(events.first.connectionId, 7);
      expect(events.first.metadata['k'], 'v');
    });

    test('enable/disable/clear call delegate functions', () async {
      bool? enabledState;
      var clearCalled = false;
      final logger = AsyncOdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) async {
          enabledState = enabled;
          return true;
        },
        clear: () async {
          clearCalled = true;
          return true;
        },
        getEventsJson: ({limit = 0}) async => '[]',
        getStatusJson: () async => '{"enabled":false,"event_count":0}',
      );

      final enabled = await logger.enable();
      final disabled = await logger.disable();
      final cleared = await logger.clear();

      expect(enabled, isTrue);
      expect(disabled, isTrue);
      expect(cleared, isTrue);
      expect(enabledState, isFalse);
      expect(clearCalled, isTrue);
    });
  });
}

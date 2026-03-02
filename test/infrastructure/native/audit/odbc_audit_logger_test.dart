import 'package:odbc_fast/infrastructure/native/audit/odbc_audit_logger.dart';
import 'package:test/test.dart';

void main() {
  group('OdbcAuditEvent', () {
    test('fromJson parses expected fields', () {
      final event = OdbcAuditEvent.fromJson(<String, Object?>{
        'timestamp_ms': 1700000000000,
        'event_type': 'query',
        'connection_id': 7,
        'query': 'SELECT 1',
        'metadata': <String, Object?>{
          'error': 'none',
          'retries': 1,
        },
      });

      expect(event.timestampMs, 1700000000000);
      expect(event.eventType, 'query');
      expect(event.connectionId, 7);
      expect(event.query, 'SELECT 1');
      expect(event.metadata['error'], 'none');
      expect(event.metadata['retries'], '1');
    });
  });

  group('OdbcAuditStatus', () {
    test('fromJson parses expected fields', () {
      final status = OdbcAuditStatus.fromJson(<String, Object?>{
        'enabled': true,
        'event_count': 9,
      });

      expect(status.enabled, isTrue);
      expect(status.eventCount, 9);
    });
  });
}

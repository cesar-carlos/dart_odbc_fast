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

    test('fromJson should_default_enabled_to_false_when_field_missing', () {
      final status = OdbcAuditStatus.fromJson(<String, Object?>{
        'event_count': 4,
      });

      expect(status.enabled, isFalse);
      expect(status.eventCount, 4);
    });

    test('fromJson should_default_event_count_to_zero_when_field_missing', () {
      final status = OdbcAuditStatus.fromJson(<String, Object?>{
        'enabled': true,
      });

      expect(status.enabled, isTrue);
      expect(status.eventCount, 0);
    });
  });

  group('OdbcAuditEvent fromJson edge cases', () {
    test('should_default_event_type_to_unknown_when_missing', () {
      final event = OdbcAuditEvent.fromJson(<String, Object?>{
        'timestamp_ms': 1700000000000,
      });

      expect(event.eventType, equals('unknown'));
      expect(event.timestampMs, equals(1700000000000));
      expect(event.connectionId, isNull);
      expect(event.query, isNull);
      expect(event.metadata, isEmpty);
    });

    test('should_default_timestamp_ms_to_zero_when_missing', () {
      final event = OdbcAuditEvent.fromJson(<String, Object?>{});
      expect(event.timestampMs, equals(0));
    });

    test('should_ignore_metadata_that_is_not_a_map', () {
      final event = OdbcAuditEvent.fromJson(<String, Object?>{
        'event_type': 'connect',
        'metadata': 'not-a-map',
      });

      expect(event.metadata, isEmpty);
    });

    test('should_stringify_each_metadata_value', () {
      final event = OdbcAuditEvent.fromJson(<String, Object?>{
        'event_type': 'connect',
        'metadata': <String, Object?>{
          'count': 42,
          'flag': true,
          'note': null,
        },
      });

      expect(event.metadata['count'], equals('42'));
      expect(event.metadata['flag'], equals('true'));
      expect(event.metadata['note'], equals(''));
    });
  });

  group('OdbcAuditLogger orchestration', () {
    test('enable should_call_setEnabled_with_true', () {
      bool? captured;
      final logger = OdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) {
          captured = enabled;
          return true;
        },
        clear: () => true,
        getEventsJson: ({limit = 0}) => null,
        getStatusJson: () => null,
      );

      expect(logger.enable(), isTrue);
      expect(captured, isTrue);
    });

    test('disable should_call_setEnabled_with_false', () {
      bool? captured;
      final logger = OdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) {
          captured = enabled;
          return true;
        },
        clear: () => true,
        getEventsJson: ({limit = 0}) => null,
        getStatusJson: () => null,
      );

      expect(logger.disable(), isTrue);
      expect(captured, isFalse);
    });

    test('clear should_call_underlying_clear_delegate', () {
      var called = 0;
      final logger = OdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) => true,
        clear: () {
          called += 1;
          return true;
        },
        getEventsJson: ({limit = 0}) => null,
        getStatusJson: () => null,
      );

      expect(logger.clear(), isTrue);
      expect(called, equals(1));
    });

    test('getStatus should_return_null_when_payload_is_null', () {
      final logger = OdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) => true,
        clear: () => true,
        getEventsJson: ({limit = 0}) => null,
        getStatusJson: () => null,
      );

      expect(logger.getStatus(), isNull);
    });

    test('getStatus should_return_null_when_payload_is_empty', () {
      final logger = OdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) => true,
        clear: () => true,
        getEventsJson: ({limit = 0}) => null,
        getStatusJson: () => '',
      );

      expect(logger.getStatus(), isNull);
    });

    test('getStatus should_return_null_when_payload_is_not_an_object', () {
      final logger = OdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) => true,
        clear: () => true,
        getEventsJson: ({limit = 0}) => null,
        getStatusJson: () => '[1, 2, 3]',
      );

      expect(logger.getStatus(), isNull);
    });

    test('getStatus should_parse_status_payload_when_valid_object', () {
      final logger = OdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) => true,
        clear: () => true,
        getEventsJson: ({limit = 0}) => null,
        getStatusJson: () => '{"enabled":true,"event_count":12}',
      );

      final status = logger.getStatus();
      expect(status, isNotNull);
      expect(status!.enabled, isTrue);
      expect(status.eventCount, equals(12));
    });

    test('getEvents should_return_empty_list_when_payload_is_null', () {
      final logger = OdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) => true,
        clear: () => true,
        getEventsJson: ({limit = 0}) => null,
        getStatusJson: () => null,
      );

      expect(logger.getEvents(), isEmpty);
    });

    test('getEvents should_return_empty_list_when_payload_is_empty_string', () {
      final logger = OdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) => true,
        clear: () => true,
        getEventsJson: ({limit = 0}) => '',
        getStatusJson: () => null,
      );

      expect(logger.getEvents(), isEmpty);
    });

    test('getEvents should_return_empty_list_when_payload_is_not_an_array', () {
      final logger = OdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) => true,
        clear: () => true,
        getEventsJson: ({limit = 0}) => '{"not":"a list"}',
        getStatusJson: () => null,
      );

      expect(logger.getEvents(), isEmpty);
    });

    test('getEvents should_parse_array_of_events_and_skip_non_objects', () {
      final logger = OdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) => true,
        clear: () => true,
        getEventsJson: ({limit = 0}) =>
            '[{"timestamp_ms":1,"event_type":"query","connection_id":2,'
            '"query":"SELECT 1","metadata":{"k":"v"}}, '
            '"ignored-scalar"]',
        getStatusJson: () => null,
      );

      final events = logger.getEvents(limit: 10);
      expect(events, hasLength(1));
      expect(events.first.eventType, equals('query'));
      expect(events.first.metadata['k'], equals('v'));
    });

    test('getEvents should_forward_limit_parameter_to_delegate', () {
      int? capturedLimit;
      OdbcAuditLogger.forTesting(
        setEnabled: ({required enabled}) => true,
        clear: () => true,
        getEventsJson: ({limit = 0}) {
          capturedLimit = limit;
          return '[]';
        },
        getStatusJson: () => null,
      ).getEvents(limit: 42);

      expect(capturedLimit, equals(42));
    });
  });
}

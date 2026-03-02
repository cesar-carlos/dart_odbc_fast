import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:test/test.dart';

void main() {
  group('OdbcNative', () {
    late OdbcNative native;

    setUp(() {
      native = OdbcNative();
    });

    tearDown(() {
      native.dispose();
    });

    test('should load library', () {
      expect(native, isNotNull);
    });

    test('should initialize environment', () {
      final result = native.init();

      expect(result, isA<bool>());
    });

    test('should handle invalid connection string', () {
      final connId = native.connect('');
      expect(connId, equals(0));
    });

    test('should get error message', () {
      final error = native.getError();
      expect(error, isA<String>());
    });

    test('should enable/disable and clear audit events', () {
      native.init();
      if (!native.supportsAuditApi) {
        return;
      }

      expect(native.setAuditEnabled(enabled: true), isTrue);
      expect(native.clearAuditEvents(), isTrue);
      expect(native.setAuditEnabled(enabled: false), isTrue);
    });

    test('should return audit events payload as json array', () {
      native.init();
      if (!native.supportsAuditApi) {
        return;
      }
      native
        ..setAuditEnabled(enabled: true)
        ..clearAuditEvents();

      final payload = native.getAuditEventsJson();

      expect(payload, isNotNull);
      expect(payload, startsWith('['));
    });

    test('should return audit status payload as json object', () {
      native.init();
      if (!native.supportsAuditApi) {
        return;
      }
      native.setAuditEnabled(enabled: true);

      final payload = native.getAuditStatusJson();

      expect(payload, isNotNull);
      expect(payload, startsWith('{'));
    });
  });
}

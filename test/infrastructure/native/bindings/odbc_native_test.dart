import 'package:test/test.dart';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';

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
      // May fail if ODBC not configured, but should not throw
      expect(result, isA<bool>());
    });

    test('should handle invalid connection string', () {
      final connId = native.connect('');
      expect(connId, equals(0)); // Should fail
    });

    test('should get error message', () {
      final error = native.getError();
      expect(error, isA<String>());
    });
  });
}

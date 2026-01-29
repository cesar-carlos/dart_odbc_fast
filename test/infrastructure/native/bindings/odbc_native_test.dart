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
  });
}

import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:test/test.dart';

void main() {
  group('ConnectionOptions', () {
    test('should use default effectiveMaxReconnectAttempts when null', () {
      const opts = ConnectionOptions(autoReconnectOnConnectionLost: true);
      expect(opts.effectiveMaxReconnectAttempts, defaultMaxReconnectAttempts);
    });

    test('should use custom maxReconnectAttempts when set', () {
      const opts = ConnectionOptions(
        autoReconnectOnConnectionLost: true,
        maxReconnectAttempts: 5,
      );
      expect(opts.effectiveMaxReconnectAttempts, 5);
    });

    test('should use default effectiveReconnectBackoff when null', () {
      const opts = ConnectionOptions(autoReconnectOnConnectionLost: true);
      expect(opts.effectiveReconnectBackoff, defaultReconnectBackoff);
    });

    test('should use custom reconnectBackoff when set', () {
      const custom = Duration(seconds: 5);
      const opts = ConnectionOptions(
        autoReconnectOnConnectionLost: true,
        reconnectBackoff: custom,
      );
      expect(opts.effectiveReconnectBackoff, custom);
    });

    test('should have defaultInitialResultBufferBytes equal to 64*1024', () {
      expect(defaultInitialResultBufferBytes, 64 * 1024);
    });

    test('should have defaultMaxReconnectAttempts equal to 3', () {
      expect(defaultMaxReconnectAttempts, 3);
    });

    test('should have defaultReconnectBackoff equal to 1 second', () {
      expect(defaultReconnectBackoff, const Duration(seconds: 1));
    });

    test(
        'loginTimeoutMs should prefer loginTimeout over connectionTimeout',
        () {
      const opts = ConnectionOptions(
        connectionTimeout: Duration(seconds: 10),
        loginTimeout: Duration(seconds: 5),
      );
      expect(opts.loginTimeoutMs, 5000);
    });

    test('loginTimeoutMs should use connectionTimeout when loginTimeout null',
        () {
      const opts = ConnectionOptions(
        connectionTimeout: Duration(seconds: 8),
      );
      expect(opts.loginTimeoutMs, 8000);
    });

    test('loginTimeoutMs should return 0 when both null', () {
      const opts = ConnectionOptions();
      expect(opts.loginTimeoutMs, 0);
    });
  });
}

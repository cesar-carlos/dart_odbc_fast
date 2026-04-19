import 'dart:convert';

import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:test/test.dart';

void main() {
  group('PoolOptions.toJson', () {
    test('returns null when no options are set', () {
      expect(const PoolOptions().toJson(), isNull);
      expect(const PoolOptions().hasAnyOption, isFalse);
    });

    test('emits the expected JSON shape with single option', () {
      final json =
          const PoolOptions(connectionTimeout: Duration(seconds: 10)).toJson();
      expect(json, isNotNull);
      final decoded = jsonDecode(json!) as Map<String, dynamic>;
      expect(decoded, {'connection_timeout_ms': 10000});
    });

    test('emits all three keys when fully set', () {
      final json = const PoolOptions(
        idleTimeout: Duration(minutes: 5),
        maxLifetime: Duration(hours: 1),
        connectionTimeout: Duration(seconds: 30),
      ).toJson();
      final decoded = jsonDecode(json!) as Map<String, dynamic>;
      expect(decoded, {
        'idle_timeout_ms': 5 * 60 * 1000,
        'max_lifetime_ms': 60 * 60 * 1000,
        'connection_timeout_ms': 30 * 1000,
      });
    });

    test('hasAnyOption reflects field state', () {
      expect(
        const PoolOptions(idleTimeout: Duration(seconds: 1)).hasAnyOption,
        isTrue,
      );
      expect(
        const PoolOptions(maxLifetime: Duration(seconds: 1)).hasAnyOption,
        isTrue,
      );
      expect(
        const PoolOptions(connectionTimeout: Duration(seconds: 1)).hasAnyOption,
        isTrue,
      );
    });
  });
}

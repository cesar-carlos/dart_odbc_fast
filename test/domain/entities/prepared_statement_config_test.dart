/// Unit tests for [PreparedStatementConfig].
library;

import 'package:odbc_fast/domain/entities/prepared_statement_config.dart';
import 'package:test/test.dart';

void main() {
  group('PreparedStatementConfig', () {
    test('default constructor uses default values', () {
      const config = PreparedStatementConfig();
      expect(config.maxCacheSize, 50);
      expect(config.ttl, isNull);
      expect(config.enabled, true);
    });

    test('custom maxCacheSize is stored', () {
      const config = PreparedStatementConfig(maxCacheSize: 100);
      expect(config.maxCacheSize, 100);
      expect(config.ttl, isNull);
      expect(config.enabled, true);
    });

    test('custom ttl is stored', () {
      const config = PreparedStatementConfig(
        ttl: Duration(minutes: 10),
      );
      expect(config.maxCacheSize, 50);
      expect(config.ttl, const Duration(minutes: 10));
      expect(config.enabled, true);
    });

    test('enabled false is stored', () {
      const config = PreparedStatementConfig(enabled: false);
      expect(config.enabled, false);
    });

    test('all custom values are stored', () {
      const config = PreparedStatementConfig(
        maxCacheSize: 25,
        ttl: Duration(seconds: 30),
        enabled: false,
      );
      expect(config.maxCacheSize, 25);
      expect(config.ttl, const Duration(seconds: 30));
      expect(config.enabled, false);
    });
  });
}

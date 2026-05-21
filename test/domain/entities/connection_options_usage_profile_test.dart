import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:test/test.dart';

void main() {
  group('ConnectionOptions.fromUsageProfile', () {
    test('legacy has no preset timeouts', () {
      final o = ConnectionOptions.fromUsageProfile(OdbcUsageProfile.legacy);
      expect(o.loginTimeout, isNull);
      expect(o.queryTimeout, isNull);
      expect(o.autoReconnectOnConnectionLost, isFalse);
      expect(o.validate(), isNull);
    });

    test('balanced presets validate', () {
      final o = ConnectionOptions.fromUsageProfile(OdbcUsageProfile.balanced);
      expect(o.loginTimeout, const Duration(seconds: 30));
      expect(o.queryTimeout, const Duration(seconds: 120));
      expect(o.autoReconnectOnConnectionLost, isTrue);
      expect(o.validate(), isNull);
    });
  });

  group('PoolOptions.fromUsageProfile', () {
    test('legacy has no pool knobs', () {
      final o = PoolOptions.fromUsageProfile(OdbcUsageProfile.legacy);
      expect(o.hasAnyOption, isFalse);
    });

    test('balanced sets eviction and acquire timeout', () {
      final o = PoolOptions.fromUsageProfile(OdbcUsageProfile.balanced);
      expect(o.hasAnyOption, isTrue);
      expect(o.idleTimeout, const Duration(minutes: 5));
      expect(o.maxLifetime, const Duration(minutes: 30));
      expect(o.connectionTimeout, const Duration(seconds: 30));
    });
  });
}

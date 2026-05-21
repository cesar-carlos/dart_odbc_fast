import 'package:odbc_fast/core/di/resolved_odbc_usage_profile.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:test/test.dart';

void main() {
  group('ConnectionOptions.fromUsageProfile', () {
    for (final profile in OdbcUsageProfile.values) {
      test(
        'should_match_resolved_profile_when_${profile.name}_is_requested',
        () {
          final options = ConnectionOptions.fromUsageProfile(profile);
          final resolved = ResolvedOdbcUsageProfile.fromUsageProfile(profile);

          expect(
            options.connectionTimeout,
            resolved.connectionOptions.connectionTimeout,
          );
          expect(options.loginTimeout, resolved.connectionOptions.loginTimeout);
          expect(options.queryTimeout, resolved.connectionOptions.queryTimeout);
          expect(
            options.autoReconnectOnConnectionLost,
            resolved.connectionOptions.autoReconnectOnConnectionLost,
          );
          expect(
            options.maxReconnectAttempts,
            resolved.connectionOptions.maxReconnectAttempts,
          );
          expect(
            options.reconnectBackoff,
            resolved.connectionOptions.reconnectBackoff,
          );
          expect(options.validate(), isNull);
        },
      );
    }

    test('legacy has no preset timeouts', () {
      final options = ConnectionOptions.fromUsageProfile(
        OdbcUsageProfile.legacy,
      );
      expect(options.loginTimeout, isNull);
      expect(options.queryTimeout, isNull);
      expect(options.autoReconnectOnConnectionLost, isFalse);
    });

    test('balanced presets validate', () {
      final options = ConnectionOptions.fromUsageProfile(
        OdbcUsageProfile.balanced,
      );
      expect(options.loginTimeout, const Duration(seconds: 30));
      expect(options.queryTimeout, const Duration(seconds: 120));
      expect(options.autoReconnectOnConnectionLost, isTrue);
    });
  });

  group('PoolOptions.fromUsageProfile', () {
    for (final profile in OdbcUsageProfile.values) {
      test(
        'should_match_resolved_pool_profile_when_${profile.name}_is_requested',
        () {
          final options = PoolOptions.fromUsageProfile(profile);
          final resolved = ResolvedOdbcUsageProfile.fromUsageProfile(profile);

          expect(options.idleTimeout, resolved.poolOptions.idleTimeout);
          expect(options.maxLifetime, resolved.poolOptions.maxLifetime);
          expect(
            options.connectionTimeout,
            resolved.poolOptions.connectionTimeout,
          );
          expect(options.hasAnyOption, resolved.poolOptions.hasAnyOption);
        },
      );
    }

    test('legacy has no pool knobs', () {
      final options = PoolOptions.fromUsageProfile(OdbcUsageProfile.legacy);
      expect(options.hasAnyOption, isFalse);
    });

    test('balanced sets eviction and acquire timeout', () {
      final options = PoolOptions.fromUsageProfile(OdbcUsageProfile.balanced);
      expect(options.hasAnyOption, isTrue);
      expect(options.idleTimeout, const Duration(minutes: 5));
      expect(options.maxLifetime, const Duration(minutes: 30));
      expect(options.connectionTimeout, const Duration(seconds: 30));
    });
  });
}

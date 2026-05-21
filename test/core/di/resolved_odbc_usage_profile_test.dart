import 'package:odbc_fast/core/di/resolved_odbc_usage_profile.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:test/test.dart';

void main() {
  group('ResolvedOdbcUsageProfile.fromUsageProfile', () {
    test('should_resolve_legacy_profile_when_requested', () {
      final resolved =
          ResolvedOdbcUsageProfile.fromUsageProfile(OdbcUsageProfile.legacy);

      expect(resolved.profile, OdbcUsageProfile.legacy);
      expect(resolved.useAsync, isFalse);
      expect(resolved.workerCount, 1);
      expect(resolved.maxPendingRequests, isNull);
      expect(resolved.backpressureMode, AsyncBackpressureMode.failFast);
      expect(resolved.backpressureTimeout, isNull);
      expect(resolved.recommendedPoolMaxSize, 4);
      expect(resolved.connectionOptions.loginTimeout, isNull);
      expect(resolved.connectionOptions.queryTimeout, isNull);
      expect(
        resolved.connectionOptions.autoReconnectOnConnectionLost,
        isFalse,
      );
      expect(resolved.poolOptions.hasAnyOption, isFalse);
    });

    test('should_resolve_balanced_profile_when_requested', () {
      final resolved =
          ResolvedOdbcUsageProfile.fromUsageProfile(OdbcUsageProfile.balanced);

      expect(resolved.profile, OdbcUsageProfile.balanced);
      expect(resolved.useAsync, isTrue);
      expect(resolved.workerCount, 2);
      expect(resolved.maxPendingRequests, 24);
      expect(resolved.backpressureMode, AsyncBackpressureMode.waitForSlot);
      expect(resolved.backpressureTimeout, const Duration(seconds: 30));
      expect(resolved.recommendedPoolMaxSize, 4);
      expect(
        resolved.connectionOptions.loginTimeout,
        const Duration(seconds: 30),
      );
      expect(
        resolved.connectionOptions.queryTimeout,
        const Duration(seconds: 120),
      );
      expect(
        resolved.connectionOptions.autoReconnectOnConnectionLost,
        isTrue,
      );
      expect(
        resolved.connectionOptions.maxReconnectAttempts,
        defaultMaxReconnectAttempts,
      );
      expect(
        resolved.connectionOptions.reconnectBackoff,
        defaultReconnectBackoff,
      );
      expect(resolved.poolOptions.idleTimeout, const Duration(minutes: 5));
      expect(resolved.poolOptions.maxLifetime, const Duration(minutes: 30));
      expect(
        resolved.poolOptions.connectionTimeout,
        const Duration(seconds: 30),
      );
    });

    test('should_resolve_balanced_flutter_profile_when_requested', () {
      final resolved = ResolvedOdbcUsageProfile.fromUsageProfile(
        OdbcUsageProfile.balancedFlutter,
      );

      expect(resolved.profile, OdbcUsageProfile.balancedFlutter);
      expect(resolved.useAsync, isTrue);
      expect(resolved.workerCount, 1);
      expect(resolved.maxPendingRequests, 16);
      expect(resolved.backpressureMode, AsyncBackpressureMode.waitForSlot);
      expect(resolved.backpressureTimeout, const Duration(seconds: 30));
      expect(resolved.recommendedPoolMaxSize, 4);
      expect(
        resolved.connectionOptions.loginTimeout,
        const Duration(seconds: 30),
      );
      expect(
        resolved.connectionOptions.queryTimeout,
        const Duration(seconds: 120),
      );
      expect(
        resolved.poolOptions.connectionTimeout,
        const Duration(seconds: 30),
      );
    });

    test('should_resolve_balanced_server_profile_when_requested', () {
      final resolved = ResolvedOdbcUsageProfile.fromUsageProfile(
        OdbcUsageProfile.balancedServer,
      );

      expect(resolved.profile, OdbcUsageProfile.balancedServer);
      expect(resolved.useAsync, isTrue);
      expect(resolved.workerCount, 4);
      expect(resolved.maxPendingRequests, 32);
      expect(resolved.backpressureMode, AsyncBackpressureMode.waitForSlot);
      expect(resolved.backpressureTimeout, const Duration(seconds: 60));
      expect(resolved.recommendedPoolMaxSize, 8);
      expect(
        resolved.connectionOptions.loginTimeout,
        const Duration(seconds: 30),
      );
      expect(
        resolved.connectionOptions.queryTimeout,
        const Duration(seconds: 120),
      );
      expect(resolved.poolOptions.idleTimeout, const Duration(minutes: 5));
    });

    test('should_resolve_high_throughput_profile_when_requested', () {
      final resolved = ResolvedOdbcUsageProfile.fromUsageProfile(
        OdbcUsageProfile.highThroughput,
      );

      expect(resolved.profile, OdbcUsageProfile.highThroughput);
      expect(resolved.useAsync, isTrue);
      expect(resolved.workerCount, 6);
      expect(resolved.maxPendingRequests, 48);
      expect(resolved.backpressureMode, AsyncBackpressureMode.waitForSlot);
      expect(resolved.backpressureTimeout, const Duration(seconds: 60));
      expect(resolved.recommendedPoolMaxSize, 12);
      expect(
        resolved.connectionOptions.loginTimeout,
        const Duration(seconds: 30),
      );
      expect(
        resolved.connectionOptions.queryTimeout,
        const Duration(seconds: 120),
      );
      expect(resolved.poolOptions.maxLifetime, const Duration(minutes: 30));
    });
  });
}

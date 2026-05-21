import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/audit/async_odbc_audit_logger.dart';
import 'package:odbc_fast/infrastructure/native/audit/odbc_audit_logger.dart';
import 'package:test/test.dart';

void main() {
  group('ServiceLocator', () {
    test('exposes async services and passes asyncWorkerCount', () {
      final locator = ServiceLocator()
        ..initialize(
          useAsync: true,
          asyncWorkerCount: 4,
          asyncMaxPendingRequests: 16,
          asyncBackpressureMode: AsyncBackpressureMode.waitForSlot,
          asyncBackpressureTimeout: const Duration(milliseconds: 250),
        );

      expect(locator.usageProfile, OdbcUsageProfile.legacy);
      expect(locator.auditLogger, isA<OdbcAuditLogger>());
      expect(locator.asyncAuditLogger, isA<AsyncOdbcAuditLogger>());
      expect(locator.asyncNativeConnection.workerCount, equals(4));
      expect(locator.asyncNativeConnection.maxPendingRequests, equals(16));
      expect(locator.resolvedUsageProfile.profile, OdbcUsageProfile.legacy);
      expect(locator.resolvedUsageProfile.useAsync, isTrue);
      expect(locator.resolvedUsageProfile.workerCount, 4);
      expect(locator.resolvedUsageProfile.maxPendingRequests, 16);
      expect(
        locator.asyncNativeConnection.backpressureMode,
        equals(AsyncBackpressureMode.waitForSlot),
      );
      expect(
        locator.resolvedUsageProfile.backpressureMode,
        equals(AsyncBackpressureMode.waitForSlot),
      );
      expect(
        locator.asyncNativeConnection.backpressureTimeout,
        equals(const Duration(milliseconds: 250)),
      );
      expect(
        locator.resolvedUsageProfile.backpressureTimeout,
        equals(const Duration(milliseconds: 250)),
      );
      locator.shutdown();
    });

    test('rejects invalid asyncWorkerCount', () {
      expect(
        () => ServiceLocator().initialize(useAsync: true, asyncWorkerCount: 0),
        throwsArgumentError,
      );
    });

    test('rejects invalid asyncMaxPendingRequests', () {
      expect(
        () => ServiceLocator().initialize(
          useAsync: true,
          asyncMaxPendingRequests: 0,
        ),
        throwsArgumentError,
      );
    });

    test('rejects invalid asyncBackpressureTimeout', () {
      expect(
        () => ServiceLocator().initialize(
          useAsync: true,
          asyncBackpressureTimeout: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
    });

    test('defaults to legacy sync with recommended getters', () {
      final locator = ServiceLocator()..initialize();
      expect(locator.usageProfile, OdbcUsageProfile.legacy);
      expect(locator.resolvedUsageProfile.profile, OdbcUsageProfile.legacy);
      expect(locator.isAsyncMode, isFalse);
      expect(locator.resolvedUsageProfile.useAsync, isFalse);
      expect(locator.resolvedUsageProfile.workerCount, 1);
      expect(locator.recommendedConnectionOptions.queryTimeout, isNull);
      expect(
        locator.resolvedUsageProfile.connectionOptions.queryTimeout,
        isNull,
      );
      expect(locator.recommendedPoolMaxSize, 4);
      expect(locator.recommendedPoolOptions.hasAnyOption, isFalse);
      locator.shutdown();
    });

    test('useAsync false overrides balanced profile to sync', () {
      final locator = ServiceLocator()
        ..initialize(
          profile: OdbcUsageProfile.balanced,
          useAsync: false,
        );
      expect(locator.usageProfile, OdbcUsageProfile.balanced);
      expect(locator.resolvedUsageProfile.profile, OdbcUsageProfile.balanced);
      expect(locator.isAsyncMode, isFalse);
      expect(locator.resolvedUsageProfile.useAsync, isFalse);
      expect(locator.resolvedUsageProfile.workerCount, 2);
      expect(
        locator.recommendedConnectionOptions.loginTimeout,
        const Duration(seconds: 30),
      );
      locator.shutdown();
    });

    test('should_expose_high_throughput_preset_when_selected', () {
      final locator = ServiceLocator()
        ..initialize(
          profile: OdbcUsageProfile.highThroughput,
        );

      expect(locator.usageProfile, OdbcUsageProfile.highThroughput);
      expect(
        locator.resolvedUsageProfile.profile,
        OdbcUsageProfile.highThroughput,
      );
      expect(locator.isAsyncMode, isTrue);
      expect(locator.resolvedUsageProfile.workerCount, 6);
      expect(locator.resolvedUsageProfile.maxPendingRequests, 48);
      expect(locator.recommendedPoolMaxSize, 12);
      locator.shutdown();
    });
  });
}

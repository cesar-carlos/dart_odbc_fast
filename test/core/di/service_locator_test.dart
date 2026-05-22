import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/audit/async_odbc_audit_logger.dart';
import 'package:odbc_fast/infrastructure/native/audit/odbc_audit_logger.dart';
import 'package:test/test.dart';

void main() {
  group('ServiceLocator', () {
    test('should_return_identical_singleton_from_factory', () {
      expect(identical(ServiceLocator(), ServiceLocator()), isTrue);
    });

    test('should_expose_sync_service_when_legacy_profile', () {
      final locator = ServiceLocator()..initialize();
      expect(locator.isAsyncMode, isFalse);
      expect(identical(locator.service, locator.syncService), isTrue);
      locator.shutdown();
    });

    test('should_expose_async_service_when_balanced_profile', () {
      final locator = ServiceLocator()
        ..initialize(profile: OdbcUsageProfile.balanced);
      expect(locator.isAsyncMode, isTrue);
      expect(identical(locator.service, locator.asyncService), isTrue);
      expect(identical(locator.service, locator.syncService), isFalse);
      locator.shutdown();
    });

    test('should_throw_when_asyncService_accessed_in_legacy_mode', () {
      final locator = ServiceLocator()..initialize();
      expect(
        () => locator.asyncService,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('async mode'),
          ),
        ),
      );
      locator.shutdown();
    });

    test('should_apply_balancedServer_preset_defaults', () {
      final locator = ServiceLocator()
        ..initialize(profile: OdbcUsageProfile.balancedServer);
      expect(locator.usageProfile, OdbcUsageProfile.balancedServer);
      expect(locator.isAsyncMode, isTrue);
      expect(locator.asyncNativeConnection.workerCount, 4);
      expect(locator.asyncNativeConnection.maxPendingRequests, 32);
      expect(
        locator.recommendedPoolMaxSize,
        OdbcUsageProfile.balancedServer.recommendedPoolMaxSize,
      );
      expect(locator.recommendedPoolOptions.hasAnyOption, isTrue);
      locator.shutdown();
    });

    test('should_clear_async_mode_and_reject_asyncService_after_shutdown', () {
      final locator = ServiceLocator()
        ..initialize(useAsync: true, asyncWorkerCount: 2);
      expect(locator.isAsyncMode, isTrue);
      locator.shutdown();
      expect(locator.isAsyncMode, isFalse);
      expect(
        () => locator.asyncService,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('async mode'),
          ),
        ),
      );
    });

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

    test('should_throw_when_asyncAuditLogger_accessed_in_legacy_mode', () {
      final locator = ServiceLocator()..initialize();
      expect(
        () => locator.asyncAuditLogger,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('async mode'),
          ),
        ),
      );
      locator.shutdown();
    });

    test('should_throw_when_asyncNativeConnection_accessed_in_legacy_mode', () {
      final locator = ServiceLocator()..initialize();
      expect(
        () => locator.asyncNativeConnection,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('async mode'),
          ),
        ),
      );
      locator.shutdown();
    });

    test('should_expose_nativeConnection_after_initialize', () {
      final locator = ServiceLocator()..initialize();
      expect(locator.nativeConnection, isNotNull);
      expect(locator.auditLogger, isA<OdbcAuditLogger>());
      locator.shutdown();
    });

    test('should_apply_balancedFlutter_preset_defaults', () {
      final locator = ServiceLocator()
        ..initialize(profile: OdbcUsageProfile.balancedFlutter);
      expect(locator.usageProfile, OdbcUsageProfile.balancedFlutter);
      expect(locator.isAsyncMode, isTrue);
      expect(locator.asyncNativeConnection.workerCount, 1);
      expect(locator.asyncNativeConnection.maxPendingRequests, 16);
      expect(
        locator.resolvedUsageProfile.backpressureMode,
        AsyncBackpressureMode.waitForSlot,
      );
      locator.shutdown();
    });

    test('should_replace_async_worker_pool_on_reinitialize', () {
      final locator = ServiceLocator()
        ..initialize(useAsync: true, asyncWorkerCount: 2);
      expect(locator.asyncNativeConnection.workerCount, 2);

      locator.initialize(useAsync: true, asyncWorkerCount: 5);
      expect(locator.asyncNativeConnection.workerCount, 5);
      locator.shutdown();
    });

    test('should_expose_async_repository_when_balanced_profile', () {
      final locator = ServiceLocator()
        ..initialize(profile: OdbcUsageProfile.balanced);
      final asyncRepo = locator.repository;

      expect(locator.isAsyncMode, isTrue);
      expect(asyncRepo, isA<IOdbcRepository>());

      locator.initialize();
      expect(locator.isAsyncMode, isFalse);
      expect(identical(locator.repository, asyncRepo), isFalse);
      locator.shutdown();
    });

    test('should_allow_zero_asyncBackpressureTimeout_override', () {
      final locator = ServiceLocator()
        ..initialize(
          useAsync: true,
          asyncBackpressureTimeout: Duration.zero,
        );

      expect(
        locator.resolvedUsageProfile.backpressureTimeout,
        Duration.zero,
      );
      locator.shutdown();
    });
  });
}

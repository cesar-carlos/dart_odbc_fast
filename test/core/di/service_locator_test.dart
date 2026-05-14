import 'package:odbc_fast/core/di/service_locator.dart';
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

      expect(locator.auditLogger, isA<OdbcAuditLogger>());
      expect(locator.asyncAuditLogger, isA<AsyncOdbcAuditLogger>());
      expect(locator.asyncNativeConnection.workerCount, equals(4));
      expect(locator.asyncNativeConnection.maxPendingRequests, equals(16));
      expect(
        locator.asyncNativeConnection.backpressureMode,
        equals(AsyncBackpressureMode.waitForSlot),
      );
      expect(
        locator.asyncNativeConnection.backpressureTimeout,
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
  });
}

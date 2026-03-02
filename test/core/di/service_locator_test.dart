import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/infrastructure/native/audit/async_odbc_audit_logger.dart';
import 'package:odbc_fast/infrastructure/native/audit/odbc_audit_logger.dart';
import 'package:test/test.dart';

void main() {
  group('ServiceLocator', () {
    test('exposes sync and async audit loggers when initialized async', () {
      final locator = ServiceLocator()..initialize(useAsync: true);

      expect(locator.auditLogger, isA<OdbcAuditLogger>());
      expect(locator.asyncAuditLogger, isA<AsyncOdbcAuditLogger>());
      locator.shutdown();
    });
  });
}

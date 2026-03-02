import 'package:odbc_fast/infrastructure/native/audit/odbc_audit_logger.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:test/test.dart';

void main() {
  group('NativeOdbcConnection', () {
    test('exposes typed audit logger wrapper', () {
      final connection = NativeOdbcConnection();
      expect(connection.auditLogger, isA<OdbcAuditLogger>());
      connection.dispose();
    });
  });
}

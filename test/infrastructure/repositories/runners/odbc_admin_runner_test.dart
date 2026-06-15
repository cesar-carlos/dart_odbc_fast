/// Unit tests for [OdbcAdminRunner].
library;

import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_admin_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:test/test.dart';

class _FakeNativeForAdmin extends NativeOdbcConnection {
  OdbcMetrics? metricsResult;
  Map<String, String>? versionResult;
  String? validateResult;
  String? capabilitiesJson;
  bool setAuditEnabledResult = true;

  @override
  OdbcMetrics? getMetrics() => metricsResult;

  @override
  Map<String, String>? getVersion() => versionResult;

  @override
  String? validateConnectionString(String connectionString) => validateResult;

  @override
  String? getDriverCapabilitiesJson(String connectionString) =>
      capabilitiesJson;

  @override
  bool setAuditEnabled({required bool enabled}) => setAuditEnabledResult;
}

void main() {
  group('OdbcAdminRunner', () {
    late _FakeNativeForAdmin native;
    late OdbcAdminRunner runner;

    setUp(() {
      native = _FakeNativeForAdmin();
      runner = OdbcAdminRunner(
        ffi: OdbcFfiDispatch(SyncBackend(native)),
        state: OdbcRepositoryState(),
      );
    });

    tearDown(() => native.dispose());

    test('should_return_ValidationError_for_empty_connection_string', () async {
      final result = await runner.validateConnectionString('  ');
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<ValidationError>());
    });

    test('should_map_sync_metrics_to_domain_OdbcMetrics', () async {
      native.metricsResult = const OdbcMetrics(
        queryCount: 3,
        errorCount: 1,
        uptimeSecs: 10,
        totalLatencyMillis: 100,
        avgLatencyMillis: 33,
      );
      final result = await runner.getMetrics();
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull()!.queryCount, equals(3));
    });

    test('should_return_version_map_when_native_succeeds', () async {
      native.versionResult = const {'api': '1.0', 'abi': '1.1'};
      final result = await runner.getVersion();
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull(), containsPair('api', '1.0'));
    });

    test('should_reject_invalid_log_level', () async {
      final result = await runner.setLogLevel(9);
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<ValidationError>());
    });
  });
}

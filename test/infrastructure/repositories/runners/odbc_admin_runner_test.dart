/// Unit tests for [OdbcAdminRunner].
library;

import 'package:odbc_fast/domain/entities/driver_capabilities.dart';
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
  String? dbmsInfoJson;
  String? auditStatusJson;
  String? auditEventsJson;
  String? metadataCacheStatsJson;
  String? detectDriverResult;
  String lastError = '';
  bool setAuditEnabledResult = true;
  bool clearAuditEventsResult = true;
  bool metadataCacheEnableResult = true;
  bool clearMetadataCacheResult = true;
  bool metadataCacheApiSupported = true;

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
  String? getConnectionDbmsInfoJson(int connectionId) => dbmsInfoJson;

  @override
  bool setAuditEnabled({required bool enabled}) => setAuditEnabledResult;

  @override
  String? getAuditStatusJson() => auditStatusJson;

  @override
  String? getAuditEventsJson({int limit = 0}) => auditEventsJson;

  @override
  bool clearAuditEvents() => clearAuditEventsResult;

  @override
  bool get supportsMetadataCacheApi => metadataCacheApiSupported;

  @override
  bool metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) =>
      metadataCacheEnableResult;

  @override
  String? getMetadataCacheStatsJson() => metadataCacheStatsJson;

  @override
  bool clearMetadataCache() => clearMetadataCacheResult;

  @override
  String? detectDriver(String connectionString) => detectDriverResult;

  @override
  String getError() => lastError;
}

void main() {
  group('OdbcAdminRunner', () {
    late _FakeNativeForAdmin native;
    late OdbcRepositoryState state;
    late OdbcAdminRunner runner;

    setUp(() {
      native = _FakeNativeForAdmin();
      state = OdbcRepositoryState();
      runner = OdbcAdminRunner(
        ffi: OdbcFfiDispatch(SyncBackend(native)),
        state: state,
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

    test(
      'should_return_ValidationError_for_empty_capabilities_connection_string',
      () async {
        final result = await runner.getDriverCapabilities('  ');
        expect(result.isError(), isTrue);
        expect(result.exceptionOrNull(), isA<ValidationError>());
      },
    );

    test('should_decode_driver_capabilities_json_map', () async {
      native.capabilitiesJson =
          '{"engine":"postgres","driver_name":"PostgreSQL",'
          '"driver_version":"16.00","max_row_array_size":2000}';
      final result = await runner.getDriverCapabilities(
        'Driver={PostgreSQL Unicode};',
      );
      expect(result.isSuccess(), isTrue);
      final map = result.getOrNull()!;
      expect(map['engine'], DatabaseEngineIds.postgres);
      expect(map['driver_name'], 'PostgreSQL');
      expect(map['max_row_array_size'], 2000);
    });

    test('should_reject_non_object_capabilities_payload', () async {
      native.capabilitiesJson = '[1,2,3]';
      final result = await runner.getDriverCapabilities('DSN=Fake');
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<QueryError>());
      expect(
        (result.exceptionOrNull()! as QueryError).message,
        contains('Invalid driver capabilities payload format'),
      );
    });

    test('should_reject_malformed_capabilities_json', () async {
      native.capabilitiesJson = '{not-json';
      final result = await runner.getDriverCapabilities('DSN=Fake');
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<QueryError>());
      expect(
        (result.exceptionOrNull()! as QueryError).message,
        contains('Invalid driver capabilities JSON'),
      );
    });

    test(
      'should_return_ValidationError_for_unknown_dbms_info_connection',
      () async {
        final result = await runner.getConnectionDbmsInfo('missing');
        expect(result.isError(), isTrue);
        expect(result.exceptionOrNull(), isA<ValidationError>());
      },
    );

    test('should_parse_live_dbms_info_json_including_version', () async {
      state.connectionIds['c1'] = 7;
      native.dbmsInfoJson = '''
{
  "dbms_name": "PostgreSQL",
  "dbms_version": "16.1",
  "engine": "postgres",
  "max_catalog_name_len": 63,
  "current_catalog": "app",
  "capabilities": {
    "driver_name": "psqlodbcw.so",
    "driver_version": "16.00.0000",
    "engine": "postgres",
    "max_row_array_size": 2000
  }
}
''';
      final result = await runner.getConnectionDbmsInfo('c1');
      expect(result.isSuccess(), isTrue);
      final info = result.getOrNull()!;
      expect(info.dbmsName, 'PostgreSQL');
      expect(info.dbmsVersion, '16.1');
      expect(info.databaseType, DatabaseType.postgresql);
      expect(info.currentCatalog, 'app');
      expect(info.capabilities.driverName, 'psqlodbcw.so');
      expect(info.capabilities.driverVersion, '16.00.0000');
    });

    test('should_reject_non_object_dbms_info_payload', () async {
      state.connectionIds['c1'] = 7;
      native.dbmsInfoJson = '[]';
      final result = await runner.getConnectionDbmsInfo('c1');
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<QueryError>());
      expect(
        (result.exceptionOrNull()! as QueryError).message,
        contains('Invalid connection DBMS info payload format'),
      );
    });

    test('should_reject_malformed_dbms_info_json', () async {
      state.connectionIds['c1'] = 7;
      native.dbmsInfoJson = '{bad';
      final result = await runner.getConnectionDbmsInfo('c1');
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<QueryError>());
      expect(
        (result.exceptionOrNull()! as QueryError).message,
        contains('Invalid connection DBMS info JSON'),
      );
    });

    test('should_use_fallback_when_capabilities_payload_is_empty', () async {
      native
        ..capabilitiesJson = ''
        ..lastError = '';
      final result = await runner.getDriverCapabilities('DSN=Fake');
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<UnsupportedFeatureError>());
      expect(
        (result.exceptionOrNull()! as UnsupportedFeatureError).message,
        contains('Driver capabilities API is unavailable'),
      );
    });

    test('should_use_fallback_when_dbms_info_payload_is_empty', () async {
      state.connectionIds['c1'] = 7;
      native
        ..dbmsInfoJson = ''
        ..lastError = '';
      final result = await runner.getConnectionDbmsInfo('c1');
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<UnsupportedFeatureError>());
    });

    test('should_decode_audit_status_json_map', () async {
      native.auditStatusJson = '{"enabled":true,"events":2}';
      final result = await runner.getAuditStatus();
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull()!['enabled'], isTrue);
      expect(result.getOrNull()!['events'], 2);
    });

    test('should_decode_audit_events_json_list', () async {
      native.auditEventsJson =
          '[{"action":"connect","meta":{"engine":"postgres"}}]';
      final result = await runner.getAuditEvents(limit: 10);
      expect(result.isSuccess(), isTrue);
      final events = result.getOrNull()!;
      expect(events, hasLength(1));
      expect(events.first['action'], 'connect');
      expect(
        (events.first['meta']! as Map<String, Object?>)['engine'],
        'postgres',
      );
    });

    test('should_reject_non_list_audit_events_payload', () async {
      native.auditEventsJson = '{"action":"connect"}';
      final result = await runner.getAuditEvents();
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<QueryError>());
    });

    test('should_reject_non_positive_metadata_cache_params', () async {
      final result = await runner.metadataCacheEnable(
        maxEntries: 0,
        ttlSeconds: 10,
      );
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<ValidationError>());
    });

    test('should_decode_metadata_cache_stats_json', () async {
      native.metadataCacheStatsJson = '{"schema_entries":3,"ttl_secs":60}';
      final result = await runner.metadataCacheStats();
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull()!['schema_entries'], 3);
    });

    test('should_return_null_detect_driver_for_empty_connection_string',
        () async {
      expect(await runner.detectDriver('  '), isNull);
    });

    test('should_return_detect_driver_name_from_native', () async {
      native.detectDriverResult = 'postgres';
      expect(
        await runner.detectDriver('Driver={PostgreSQL};'),
        'postgres',
      );
    });

    test('should_return_null_worker_pool_stats_on_sync_backend', () async {
      expect(await runner.getWorkerPoolStats(), isNull);
    });

    test('should_succeed_set_audit_enabled_when_native_returns_true', () async {
      native.setAuditEnabledResult = true;
      final result = await runner.setAuditEnabled(enabled: true);
      expect(result.isSuccess(), isTrue);
    });
  });
}

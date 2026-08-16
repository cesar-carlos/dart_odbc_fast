import 'dart:convert';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities_mapper.dart';
import 'package:odbc_fast/infrastructure/native/native_bcp_runtime.dart';
import 'package:test/test.dart';

import 'bindings/fake_odbc_bindings.dart';
import 'bindings/test_odbc_bindings.dart';

void main() {
  group('DatabaseType.fromDriverName (heuristic)', () {
    test('detects SQL Server (incl. real DBMS name)', () {
      expect(DatabaseType.fromDriverName('SQL Server'), DatabaseType.sqlServer);
      expect(DatabaseType.fromDriverName('sqlserver'), DatabaseType.sqlServer);
      expect(DatabaseType.fromDriverName('MSSQL'), DatabaseType.sqlServer);
      expect(
        DatabaseType.fromDriverName('Microsoft SQL Server'),
        DatabaseType.sqlServer,
      );
    });

    test('detects PostgreSQL', () {
      expect(
        DatabaseType.fromDriverName('PostgreSQL'),
        DatabaseType.postgresql,
      );
      expect(DatabaseType.fromDriverName('postgres'), DatabaseType.postgresql);
    });

    test('detects MySQL', () {
      expect(DatabaseType.fromDriverName('MySQL'), DatabaseType.mysql);
      expect(DatabaseType.fromDriverName('mysql'), DatabaseType.mysql);
    });

    test('distinguishes MariaDB from MySQL', () {
      expect(DatabaseType.fromDriverName('MariaDB'), DatabaseType.mariadb);
      expect(
        DatabaseType.fromDriverName('mariadb 11.0'),
        DatabaseType.mariadb,
      );
    });

    test('detects SQLite', () {
      expect(DatabaseType.fromDriverName('SQLite'), DatabaseType.sqlite);
      expect(DatabaseType.fromDriverName('sqlite'), DatabaseType.sqlite);
    });

    test('detects Oracle', () {
      expect(DatabaseType.fromDriverName('Oracle'), DatabaseType.oracle);
      expect(DatabaseType.fromDriverName('oracle'), DatabaseType.oracle);
    });

    test('distinguishes Sybase ASE and ASA (Anywhere)', () {
      expect(
        DatabaseType.fromDriverName('Adaptive Server Enterprise'),
        DatabaseType.sybaseAse,
      );
      expect(DatabaseType.fromDriverName('Sybase ASE'), DatabaseType.sybaseAse);
      expect(
        DatabaseType.fromDriverName('Adaptive Server Anywhere'),
        DatabaseType.sybaseAsa,
      );
      expect(
        DatabaseType.fromDriverName('SQL Anywhere 17'),
        DatabaseType.sybaseAsa,
      );
    });

    test('detects DB2/Snowflake/Redshift/BigQuery/MongoDB', () {
      expect(DatabaseType.fromDriverName('IBM Db2'), DatabaseType.db2);
      expect(DatabaseType.fromDriverName('Snowflake'), DatabaseType.snowflake);
      expect(
        DatabaseType.fromDriverName('Amazon Redshift'),
        DatabaseType.redshift,
      );
      expect(
        DatabaseType.fromDriverName('Google BigQuery'),
        DatabaseType.bigquery,
      );
      expect(DatabaseType.fromDriverName('MongoDB'), DatabaseType.mongodb);
    });

    test('returns unknown for unrecognized driver', () {
      expect(DatabaseType.fromDriverName('FantasyDB'), DatabaseType.unknown);
      expect(DatabaseType.fromDriverName(''), DatabaseType.unknown);
    });

    test('should_align_with_rust_engine_from_name_edge_cases', () {
      expect(
        DatabaseType.fromDriverName('mysqlserver'),
        DatabaseType.mysql,
      );
      expect(
        DatabaseType.fromDriverName('sqlsrv32'),
        DatabaseType.sqlServer,
      );
      expect(
        DatabaseType.fromDriverName('  PostgreSQL  '),
        DatabaseType.postgresql,
      );
      expect(DatabaseType.fromDriverName('DB2'), DatabaseType.db2);
    });

    test('should_map_sybase_asa_via_asa_plus_sybase_token', () {
      expect(
        DatabaseType.fromDriverName('Sybase ASA'),
        DatabaseType.sybaseAsa,
      );
    });

    test('should_map_unqualified_sybase_and_ase_plus_adaptive_to_ase', () {
      expect(DatabaseType.fromDriverName('Sybase'), DatabaseType.sybaseAse);
      expect(
        DatabaseType.fromDriverName('Adaptive ASE'),
        DatabaseType.sybaseAse,
      );
    });
  });

  group('DatabaseType.fromEngineId (canonical)', () {
    test('round-trips every canonical engine id', () {
      const cases = <String, DatabaseType>{
        DatabaseEngineIds.sqlserver: DatabaseType.sqlServer,
        DatabaseEngineIds.postgres: DatabaseType.postgresql,
        DatabaseEngineIds.mysql: DatabaseType.mysql,
        DatabaseEngineIds.mariadb: DatabaseType.mariadb,
        DatabaseEngineIds.oracle: DatabaseType.oracle,
        DatabaseEngineIds.sybaseAse: DatabaseType.sybaseAse,
        DatabaseEngineIds.sybaseAsa: DatabaseType.sybaseAsa,
        DatabaseEngineIds.sqlite: DatabaseType.sqlite,
        DatabaseEngineIds.db2: DatabaseType.db2,
        DatabaseEngineIds.snowflake: DatabaseType.snowflake,
        DatabaseEngineIds.redshift: DatabaseType.redshift,
        DatabaseEngineIds.bigquery: DatabaseType.bigquery,
        DatabaseEngineIds.mongodb: DatabaseType.mongodb,
        DatabaseEngineIds.unknown: DatabaseType.unknown,
      };
      for (final entry in cases.entries) {
        expect(
          DatabaseType.fromEngineId(entry.key),
          entry.value,
          reason: 'engine id ${entry.key} should map to ${entry.value}',
        );
      }
    });

    test('unknown id falls back to unknown', () {
      expect(
        DatabaseType.fromEngineId('totally_made_up'),
        DatabaseType.unknown,
      );
      expect(DatabaseType.fromEngineId(''), DatabaseType.unknown);
    });
  });

  group('DriverCapabilitiesMapper.fromJson', () {
    test('parses expected fields and prefers engine id', () {
      final caps = DriverCapabilitiesMapper.fromJson(<String, Object?>{
        'supports_prepared_statements': true,
        'supports_batch_operations': true,
        'supports_streaming': true,
        'max_row_array_size': 2000,
        'driver_name': 'PostgreSQL',
        'driver_version': '15.0',
        'engine': DatabaseEngineIds.postgres,
      });

      expect(caps.supportsPreparedStatements, isTrue);
      expect(caps.supportsBatchOperations, isTrue);
      expect(caps.supportsStreaming, isTrue);
      expect(caps.maxRowArraySize, 2000);
      expect(caps.driverName, 'PostgreSQL');
      expect(caps.driverVersion, '15.0');
      expect(caps.engineId, DatabaseEngineIds.postgres);
      expect(caps.databaseType, DatabaseType.postgresql);
      expect(caps.supportsNativeBcp, isFalse);
    });

    test('should_keep_unknown_type_when_engine_missing', () {
      final caps = DriverCapabilitiesMapper.fromJson(<String, Object?>{
        'driver_name': 'Microsoft SQL Server',
      });
      expect(caps.databaseType, DatabaseType.unknown);
      expect(caps.engineId, DatabaseEngineIds.unknown);
    });

    test('parses supports_native_bcp for SQL Server', () {
      final caps = DriverCapabilitiesMapper.fromJson(<String, Object?>{
        'driver_name': 'SQL Server',
        'engine': DatabaseEngineIds.sqlserver,
        'supports_native_bcp': true,
      });
      expect(caps.supportsNativeBcp, isTrue);
      expect(caps.databaseType, DatabaseType.sqlServer);
    });

    test('defaults supports_native_bcp to false', () {
      final caps = DriverCapabilitiesMapper.fromJson(<String, Object?>{});
      expect(caps.supportsNativeBcp, isFalse);
    });

    test('uses defaults for missing fields', () {
      final caps = DriverCapabilitiesMapper.fromJson(<String, Object?>{});
      expect(caps.supportsPreparedStatements, isTrue);
      expect(caps.supportsBatchOperations, isTrue);
      expect(caps.supportsStreaming, isTrue);
      expect(caps.maxRowArraySize, 1000);
      expect(caps.driverName, 'Unknown');
      expect(caps.driverVersion, 'Unknown');
      expect(caps.databaseType, DatabaseType.unknown);
      expect(caps.engineId, DatabaseEngineIds.unknown);
      expect(caps.supportsNativeBcp, isFalse);
    });

    test('should_parse_jsonDecode_map_via_asJsonMap', () {
      final decoded = jsonDecode(
        '{"engine":"sqlite","driver_name":"SQLite","max_row_array_size":1000}',
      );
      final map = DriverCapabilitiesMapper.asJsonMap(decoded);
      expect(map, isNotNull);
      final caps = DriverCapabilitiesMapper.fromJson(map!);
      expect(caps.engineId, DatabaseEngineIds.sqlite);
      expect(caps.databaseType, DatabaseType.sqlite);
    });
  });

  group('DriverCapabilitiesMapper.asJsonMap', () {
    test('should_return_null_when_value_is_not_a_map', () {
      expect(DriverCapabilitiesMapper.asJsonMap(null), isNull);
      expect(DriverCapabilitiesMapper.asJsonMap('{"a":1}'), isNull);
      expect(DriverCapabilitiesMapper.asJsonMap(<Object?>[1, 2]), isNull);
    });

    test('should_normalize_nested_lists_and_non_string_keys', () {
      final map = DriverCapabilitiesMapper.asJsonMap(<Object?, Object?>{
        1: <Object?>[
          <String, Object?>{'engine': 'sqlite'},
          2,
        ],
      });
      expect(map, isNotNull);
      expect(map!.containsKey('1'), isTrue);
      final nested = map['1']! as List<Object?>;
      expect(nested, hasLength(2));
      expect(nested.first, isA<Map<String, Object?>>());
      expect(
        (nested.first! as Map<String, Object?>)['engine'],
        'sqlite',
      );
      expect(nested[1], 2);
    });
  });

  group('isNativeBcpAvailable', () {
    test('should_be_false_without_runtime_env_even_when_capability_true', () {
      const caps = DriverCapabilities(
        supportsPreparedStatements: true,
        supportsBatchOperations: true,
        supportsStreaming: true,
        maxRowArraySize: 2000,
        driverName: 'SQL Server',
        driverVersion: 'Unknown',
        databaseType: DatabaseType.sqlServer,
        engineId: DatabaseEngineIds.sqlserver,
        supportsNativeBcp: true,
      );
      expect(isNativeBcpAvailable(caps), isFalse);
    });

    test('should_be_false_when_capability_false', () {
      const caps = DriverCapabilities(
        supportsPreparedStatements: true,
        supportsBatchOperations: true,
        supportsStreaming: true,
        maxRowArraySize: 1000,
        driverName: 'PostgreSQL',
        driverVersion: 'Unknown',
        databaseType: DatabaseType.postgresql,
        engineId: DatabaseEngineIds.postgres,
        supportsNativeBcp: false,
      );
      expect(isNativeBcpAvailable(caps), isFalse);
    });
  });

  group('DriverCapabilitiesMapper.dbmsInfoFromJson', () {
    test('parses live introspection JSON with engine id', () {
      final info = DriverCapabilitiesMapper.dbmsInfoFromJson(<String, Object?>{
        'dbms_name': 'PostgreSQL',
        'dbms_version': '16.1',
        'engine': DatabaseEngineIds.postgres,
        'max_catalog_name_len': 63,
        'max_schema_name_len': 63,
        'max_table_name_len': 63,
        'max_column_name_len': 63,
        'current_catalog': 'production',
        'capabilities': <String, Object?>{
          'supports_prepared_statements': true,
          'supports_batch_operations': true,
          'supports_streaming': true,
          'max_row_array_size': 2000,
          'driver_name': 'PostgreSQL',
          'driver_version': '15.4',
          'engine': DatabaseEngineIds.postgres,
        },
      });

      expect(info.dbmsName, 'PostgreSQL');
      expect(info.dbmsVersion, '16.1');
      expect(info.engineId, DatabaseEngineIds.postgres);
      expect(info.databaseType, DatabaseType.postgresql);
      expect(info.maxCatalogNameLen, 63);
      expect(info.maxSchemaNameLen, 63);
      expect(info.maxTableNameLen, 63);
      expect(info.maxColumnNameLen, 63);
      expect(info.currentCatalog, 'production');
      expect(info.capabilities.driverVersion, '15.4');
      expect(info.capabilities.databaseType, DatabaseType.postgresql);
    });

    test('synthesises capabilities when missing', () {
      final info = DriverCapabilitiesMapper.dbmsInfoFromJson(<String, Object?>{
        'dbms_name': 'MariaDB',
        'engine': DatabaseEngineIds.mariadb,
      });
      expect(info.databaseType, DatabaseType.mariadb);
      expect(info.capabilities.driverName, 'MariaDB');
      expect(info.maxCatalogNameLen, 0);
      expect(info.dbmsVersion, isEmpty);
    });

    test('should_synthesise_capabilities_when_nested_value_is_not_a_map', () {
      final info = DriverCapabilitiesMapper.dbmsInfoFromJson(<String, Object?>{
        'dbms_name': 'PostgreSQL',
        'engine': DatabaseEngineIds.postgres,
        'capabilities': 'not-a-map',
      });
      expect(info.databaseType, DatabaseType.postgresql);
      expect(info.capabilities.driverName, 'PostgreSQL');
      expect(info.capabilities.engineId, DatabaseEngineIds.postgres);
      expect(info.capabilities.driverVersion, 'Unknown');
    });

    test('should_parse_nested_capabilities_from_jsonDecode_maps', () {
      final decoded = jsonDecode('''
{
  "dbms_name": "PostgreSQL",
  "dbms_version": "16.2",
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
''');
      final map = DriverCapabilitiesMapper.asJsonMap(decoded);
      expect(map, isNotNull);
      final info = DriverCapabilitiesMapper.dbmsInfoFromJson(map!);
      expect(info.dbmsVersion, '16.2');
      expect(info.databaseType, DatabaseType.postgresql);
      expect(info.capabilities.driverName, 'psqlodbcw.so');
      expect(info.capabilities.driverVersion, '16.00.0000');
      expect(info.capabilities.maxRowArraySize, 2000);
    });
  });

  group('OdbcDriverCapabilities (FFI)', () {
    test('getCapabilities returns parsed object when API supported', () {
      final native = OdbcNative()..init();
      if (!native.supportsDriverCapabilitiesApi) {
        native.dispose();
        return;
      }
      final wrapper = OdbcDriverCapabilities(native);
      final caps = wrapper.getCapabilities(
        'Driver={SQL Server};Server=localhost;Database=test;',
      );
      native.dispose();

      expect(caps, isNotNull);
      expect(caps!.driverName, 'SQL Server');
      expect(caps.engineId, DatabaseEngineIds.sqlserver);
      expect(caps.databaseType, DatabaseType.sqlServer);
      expect(caps.supportsPreparedStatements, isTrue);
    });

    test('getCapabilities returns defaults for unknown driver', () {
      final native = OdbcNative()..init();
      if (!native.supportsDriverCapabilitiesApi) {
        native.dispose();
        return;
      }
      final wrapper = OdbcDriverCapabilities(native);
      final caps = wrapper.getCapabilities(
        'Driver={UnknownDriver};Server=localhost;',
      );
      native.dispose();

      expect(caps, isNotNull);
      expect(caps!.driverName, 'Unknown');
      expect(caps.databaseType, DatabaseType.unknown);
      expect(caps.engineId, DatabaseEngineIds.unknown);
      expect(caps.supportsPreparedStatements, isTrue);
      expect(caps.maxRowArraySize, 1000);
    });
  });

  group('OdbcDriverCapabilities (stubbed FFI)', () {
    test('should_return_null_capabilities_when_api_unsupported', () {
      final native = OdbcNative.withBindings(FakeOdbcBindings.legacyMinimal());
      addTearDown(native.dispose);
      final wrapper = OdbcDriverCapabilities(native);
      expect(wrapper.supportsApi, isFalse);
      expect(wrapper.getCapabilities('DSN=x'), isNull);
    });

    test('should_return_null_capabilities_for_non_object_json', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          capabilities: const TestOdbcBindingsCapabilities(
            supportsDriverCapabilitiesApi: true,
          ),
          overrides: TestOdbcBindingsOverrides(
            getDriverCapabilities: (_, buf, bufLen, outWritten) {
              FakeOdbcBindings.writePayload(
                buf,
                bufLen,
                outWritten,
                utf8.encode('[1,2]'),
              );
              return 0;
            },
          ),
        ),
      );
      addTearDown(native.dispose);
      expect(
        OdbcDriverCapabilities(native).getCapabilities('DSN=x'),
        isNull,
      );
    });

    test('should_return_null_dbms_info_when_api_unsupported', () {
      final native = OdbcNative.withBindings(FakeOdbcBindings.legacyMinimal());
      addTearDown(native.dispose);
      expect(native.supportsConnectionDbmsInfoApi, isFalse);
      expect(
        OdbcDriverCapabilities(native).getDbmsInfoForConnection(1),
        isNull,
      );
    });

    test('should_parse_stubbed_dbms_info_json_including_version', () {
      const payload = '{"dbms_name":"PostgreSQL","dbms_version":"16.1",'
          '"engine":"postgres","max_catalog_name_len":63,'
          '"current_catalog":"app","capabilities":{"engine":"postgres",'
          '"driver_name":"psqlodbcw.so","driver_version":"16.00.0000",'
          '"max_row_array_size":2000}}';
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          capabilities: const TestOdbcBindingsCapabilities(
            supportsConnectionDbmsInfoApi: true,
          ),
          overrides: TestOdbcBindingsOverrides(
            getConnectionDbmsInfo: (connId, buf, bufLen, outWritten) {
              expect(connId, 7);
              FakeOdbcBindings.writePayload(
                buf,
                bufLen,
                outWritten,
                utf8.encode(payload),
              );
              return 0;
            },
          ),
        ),
      );
      addTearDown(native.dispose);

      final info = OdbcDriverCapabilities(native).getDbmsInfoForConnection(7);
      expect(info, isNotNull);
      expect(info!.dbmsName, 'PostgreSQL');
      expect(info.dbmsVersion, '16.1');
      expect(info.databaseType, DatabaseType.postgresql);
      expect(info.currentCatalog, 'app');
      expect(info.capabilities.driverName, 'psqlodbcw.so');
      expect(info.capabilities.driverVersion, '16.00.0000');
    });

    test('should_return_null_dbms_info_for_non_object_json', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          capabilities: const TestOdbcBindingsCapabilities(
            supportsConnectionDbmsInfoApi: true,
          ),
          overrides: TestOdbcBindingsOverrides(
            getConnectionDbmsInfo: (_, buf, bufLen, outWritten) {
              FakeOdbcBindings.writePayload(
                buf,
                bufLen,
                outWritten,
                utf8.encode('[]'),
              );
              return 0;
            },
          ),
        ),
      );
      addTearDown(native.dispose);
      expect(
        OdbcDriverCapabilities(native).getDbmsInfoForConnection(1),
        isNull,
      );
    });
  });
}

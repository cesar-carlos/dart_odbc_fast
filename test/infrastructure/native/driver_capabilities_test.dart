import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities.dart';
import 'package:test/test.dart';

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

  group('DriverCapabilities.fromJson', () {
    test('parses expected fields and prefers engine id', () {
      final caps = DriverCapabilities.fromJson(<String, Object?>{
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
    });

    test('falls back to driver-name heuristic when engine missing', () {
      final caps = DriverCapabilities.fromJson(<String, Object?>{
        'driver_name': 'Microsoft SQL Server',
      });
      expect(caps.databaseType, DatabaseType.sqlServer);
      expect(caps.engineId, DatabaseEngineIds.unknown);
    });

    test('uses defaults for missing fields', () {
      final caps = DriverCapabilities.fromJson(<String, Object?>{});
      expect(caps.supportsPreparedStatements, isTrue);
      expect(caps.supportsBatchOperations, isTrue);
      expect(caps.supportsStreaming, isTrue);
      expect(caps.maxRowArraySize, 1000);
      expect(caps.driverName, 'Unknown');
      expect(caps.driverVersion, 'Unknown');
      expect(caps.databaseType, DatabaseType.unknown);
      expect(caps.engineId, DatabaseEngineIds.unknown);
    });
  });

  group('DbmsInfo.fromJson', () {
    test('parses live introspection JSON with engine id', () {
      final info = DbmsInfo.fromJson(<String, Object?>{
        'dbms_name': 'PostgreSQL',
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
      final info = DbmsInfo.fromJson(<String, Object?>{
        'dbms_name': 'MariaDB',
        'engine': DatabaseEngineIds.mariadb,
      });
      expect(info.databaseType, DatabaseType.mariadb);
      expect(info.capabilities.driverName, 'MariaDB');
      expect(info.maxCatalogNameLen, 0);
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
}

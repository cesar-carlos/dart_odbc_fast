import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities.dart';
import 'package:test/test.dart';

void main() {
  group('DatabaseType', () {
    test('fromDriverName detects SQL Server', () {
      expect(DatabaseType.fromDriverName('SQL Server'), DatabaseType.sqlServer);
      expect(DatabaseType.fromDriverName('sqlserver'), DatabaseType.sqlServer);
      expect(DatabaseType.fromDriverName('MSSQL'), DatabaseType.sqlServer);
    });

    test('fromDriverName detects PostgreSQL', () {
      expect(
        DatabaseType.fromDriverName('PostgreSQL'),
        DatabaseType.postgresql,
      );
      expect(DatabaseType.fromDriverName('postgres'), DatabaseType.postgresql);
    });

    test('fromDriverName detects MySQL', () {
      expect(DatabaseType.fromDriverName('MySQL'), DatabaseType.mysql);
      expect(DatabaseType.fromDriverName('mysql'), DatabaseType.mysql);
    });

    test('fromDriverName detects SQLite', () {
      expect(DatabaseType.fromDriverName('SQLite'), DatabaseType.sqlite);
      expect(DatabaseType.fromDriverName('sqlite'), DatabaseType.sqlite);
    });

    test('fromDriverName detects Oracle', () {
      expect(DatabaseType.fromDriverName('Oracle'), DatabaseType.oracle);
      expect(DatabaseType.fromDriverName('oracle'), DatabaseType.oracle);
    });

    test('fromDriverName detects Sybase', () {
      expect(DatabaseType.fromDriverName('Sybase'), DatabaseType.sybase);
      expect(DatabaseType.fromDriverName('sybase'), DatabaseType.sybase);
    });

    test('fromDriverName returns unknown for unrecognized driver', () {
      expect(DatabaseType.fromDriverName('Unknown'), DatabaseType.unknown);
      expect(DatabaseType.fromDriverName(''), DatabaseType.unknown);
    });
  });

  group('DriverCapabilities', () {
    test('fromJson parses expected fields', () {
      final caps = DriverCapabilities.fromJson(<String, Object?>{
        'supports_prepared_statements': true,
        'supports_batch_operations': true,
        'supports_streaming': true,
        'max_row_array_size': 2000,
        'driver_name': 'PostgreSQL',
        'driver_version': '15.0',
      });

      expect(caps.supportsPreparedStatements, isTrue);
      expect(caps.supportsBatchOperations, isTrue);
      expect(caps.supportsStreaming, isTrue);
      expect(caps.maxRowArraySize, 2000);
      expect(caps.driverName, 'PostgreSQL');
      expect(caps.driverVersion, '15.0');
      expect(caps.databaseType, DatabaseType.postgresql);
    });

    test('fromJson uses defaults for missing fields', () {
      final caps = DriverCapabilities.fromJson(<String, Object?>{});

      expect(caps.supportsPreparedStatements, isTrue);
      expect(caps.supportsBatchOperations, isTrue);
      expect(caps.supportsStreaming, isTrue);
      expect(caps.maxRowArraySize, 1000);
      expect(caps.driverName, 'Unknown');
      expect(caps.driverVersion, 'Unknown');
      expect(caps.databaseType, DatabaseType.unknown);
    });
  });

  group('OdbcDriverCapabilities', () {
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
      expect(caps.supportsPreparedStatements, isTrue);
      expect(caps.maxRowArraySize, 1000);
    });
  });
}

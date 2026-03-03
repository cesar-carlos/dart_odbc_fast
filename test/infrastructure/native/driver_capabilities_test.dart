import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities.dart';
import 'package:test/test.dart';

void main() {
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
    });

    test('fromJson uses defaults for missing fields', () {
      final caps = DriverCapabilities.fromJson(<String, Object?>{});

      expect(caps.supportsPreparedStatements, isTrue);
      expect(caps.supportsBatchOperations, isTrue);
      expect(caps.supportsStreaming, isTrue);
      expect(caps.maxRowArraySize, 1000);
      expect(caps.driverName, 'Unknown');
      expect(caps.driverVersion, 'Unknown');
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
      expect(caps.supportsPreparedStatements, isTrue);
      expect(caps.maxRowArraySize, 1000);
    });
  });
}

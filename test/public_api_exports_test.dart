import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

void main() {
  group('public API exports', () {
    test('exports pool option types', () {
      const options = PoolOptions(
        connectionTimeout: Duration(seconds: 5),
      );
      expect(options.hasAnyOption, isTrue);
      expect(OdbcPoolFactory, isNotNull);
    });

    test('exports driver capability types', () {
      final capabilities = DriverCapabilities.fromJson(
        const {
          'driver_name': 'mock',
          'driver_version': '1.0',
          'engine': DatabaseEngineIds.sqlite,
        },
      );
      expect(capabilities.databaseType, DatabaseType.sqlite);

      final info = DbmsInfo.fromJson(
        const {
          'dbms_name': 'SQLite',
          'engine': DatabaseEngineIds.sqlite,
        },
      );
      expect(info.databaseType, DatabaseType.sqlite);
    });

    test('exports driver feature helper types', () {
      expect(DmlVerb.insert.code, equals(0));
      expect(const SessionOptions().toJson(), isEmpty);
      expect(OdbcDriverFeatures, isNotNull);
    });
  });
}

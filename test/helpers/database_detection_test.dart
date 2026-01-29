import 'package:test/test.dart';

import 'load_env.dart';

void main() {
  group('Database Detection', () {
    test('detectDatabaseType identifies SQL Server', () {
      const dsn1 = 'Driver={SQL Server Native Client 11.0};Server=localhost';
      expect(detectDatabaseType(dsn1), DatabaseType.sqlServer);

      const dsn2 = 'Driver={ODBC Driver 17 for SQL Server};Server=localhost';
      expect(detectDatabaseType(dsn2), DatabaseType.sqlServer);

      const dsn3 = 'DRIVER=SQLSERVER;SERVER=localhost';
      expect(detectDatabaseType(dsn3), DatabaseType.sqlServer);
    });

    test('detectDatabaseType identifies PostgreSQL', () {
      const dsn1 = 'Driver={PostgreSQL Unicode};Server=localhost';
      expect(detectDatabaseType(dsn1), DatabaseType.postgresql);

      const dsn2 = 'Driver={PostgreSQL ANSI};Server=localhost';
      expect(detectDatabaseType(dsn2), DatabaseType.postgresql);

      const dsn3 = 'DRIVER=PostgreSQL;SERVER=localhost';
      expect(detectDatabaseType(dsn3), DatabaseType.postgresql);
    });

    test('detectDatabaseType identifies MySQL', () {
      const dsn1 = 'Driver={MySQL ODBC 8.0 Driver};Server=localhost';
      expect(detectDatabaseType(dsn1), DatabaseType.mysql);

      const dsn2 = 'DRIVER=MySQL;SERVER=localhost';
      expect(detectDatabaseType(dsn2), DatabaseType.mysql);
    });

    test('detectDatabaseType identifies Oracle', () {
      const dsn1 = 'Driver={Oracle ODBC Driver};Server=localhost';
      expect(detectDatabaseType(dsn1), DatabaseType.oracle);
    });

    test('detectDatabaseType returns unknown for unrecognized drivers', () {
      const dsn1 = 'Driver={Unknown Driver};Server=localhost';
      expect(detectDatabaseType(dsn1), DatabaseType.unknown);

      const dsn2 = '';
      expect(detectDatabaseType(dsn2), DatabaseType.unknown);

      expect(detectDatabaseType(null), DatabaseType.unknown);
    });

    test('isDatabaseType checks current test database', () {
      loadTestEnv();
      final dbType = getTestDatabaseType();

      // Should match itself
      expect(isDatabaseType([dbType]), isTrue);

      // Should not match if not in list
      if (dbType != DatabaseType.unknown) {
        expect(isDatabaseType([DatabaseType.unknown]), isFalse);
      }
    });

    test('skipIfDatabase returns skip reason when database matches', () {
      final reason = skipIfDatabase(
        [DatabaseType.sqlServer],
        reason: 'Custom reason',
      );

      // If running on SQL Server, should return skip reason
      if (isDatabaseType([DatabaseType.sqlServer])) {
        expect(reason, equals('Custom reason'));
      } else {
        expect(reason, isNull);
      }
    });

    test('skipUnlessDatabase returns skip reason when database does not match',
        () {
      final reason = skipUnlessDatabase(
        [DatabaseType.postgresql],
        reason: 'PostgreSQL only',
      );

      // If NOT running on PostgreSQL, should return skip reason
      if (!isDatabaseType([DatabaseType.postgresql])) {
        expect(reason, equals('PostgreSQL only'));
      } else {
        expect(reason, isNull);
      }
    });

    test('skipIfDatabase uses default reason', () {
      final reason = skipIfDatabase([DatabaseType.sqlServer]);

      if (isDatabaseType([DatabaseType.sqlServer])) {
        expect(reason, contains('Not supported on'));
        expect(reason, contains('sqlServer'));
      }
    });

    test('skipUnlessDatabase uses default reason', () {
      final reason = skipUnlessDatabase([DatabaseType.mysql]);

      if (!isDatabaseType([DatabaseType.mysql])) {
        expect(reason, contains('Only supported on'));
        expect(reason, contains('mysql'));
      }
    });
  });
}

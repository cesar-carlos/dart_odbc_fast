import 'package:odbc_fast/domain/builders/connection_string_builder.dart';
import 'package:test/test.dart';

void main() {
  group('ConnectionStringBuilder', () {
    test('build returns empty when nothing set', () {
      final s = ConnectionStringBuilder().build();
      expect(s, isEmpty);
    });

    test('build includes driver server database credentials', () {
      final s = ConnectionStringBuilder()
          .server('localhost')
          .database('mydb')
          .credentials('u', 'p')
          .build();
      expect(s, contains('Server=localhost'));
      expect(s, contains('Database=mydb'));
      expect(s, contains('Uid=u'));
      expect(s, contains('Pwd=p'));
    });

    test('option adds custom key-value pairs', () {
      final s = ConnectionStringBuilder()
          .server('x')
          .option('Foo', 'Bar')
          .option('Baz', 'Qux')
          .build();
      expect(s, contains('Foo=Bar'));
      expect(s, contains('Baz=Qux'));
    });

    test('trusted adds Trusted_Connection=yes', () {
      final s = ConnectionStringBuilder()
          .server('x')
          .trusted()
          .build();
      expect(s, contains('Trusted_Connection=yes'));
    });

    test('port is included when set', () {
      final s = ConnectionStringBuilder()
          .server('localhost')
          .port(1433)
          .build();
      expect(s, contains('Port=1433'));
    });
  });

  group('SqlServerBuilder', () {
    test('produces SQL Server connection string', () {
      final s = SqlServerBuilder()
          .server('localhost')
          .database('AdventureWorks')
          .credentials('sa', 'secret')
          .build();
      expect(s, contains(r'Driver={SQL Server}'));
      expect(s, contains('Server=localhost'));
      expect(s, contains('Database=AdventureWorks'));
      expect(s, contains('Uid=sa'));
      expect(s, contains('Pwd=secret'));
    });

    test('trusted connection omits uid/pwd', () {
      final s = SqlServerBuilder()
          .server('localhost')
          .database('AdventureWorks')
          .trusted()
          .build();
      expect(s, contains('Trusted_Connection=yes'));
      expect(s, isNot(contains('Uid=')));
      expect(s, isNot(contains('Pwd=')));
    });
  });

  group('PostgreSqlBuilder', () {
    test('produces PostgreSQL connection string with default port', () {
      final s = PostgreSqlBuilder()
          .server('localhost')
          .database('testdb')
          .credentials('postgres', 'pw')
          .build();
      expect(s, contains(r'Driver={PostgreSQL Unicode}'));
      expect(s, contains('Port=5432'));
      expect(s, contains('Database=testdb'));
    });

    test('port can be overridden', () {
      final s = PostgreSqlBuilder()
          .server('localhost')
          .port(5433)
          .build();
      expect(s, contains('Port=5433'));
    });
  });

  group('MySqlBuilder', () {
    test('produces MySQL connection string with default port', () {
      final s = MySqlBuilder()
          .server('localhost')
          .database('mydb')
          .credentials('root', 'pw')
          .build();
      expect(s, contains(r'Driver={MySQL ODBC 8.0 Driver}'));
      expect(s, contains('Port=3306'));
      expect(s, contains('Database=mydb'));
    });

    test('port can be overridden', () {
      final s = MySqlBuilder()
          .server('localhost')
          .port(3307)
          .build();
      expect(s, contains('Port=3307'));
    });
  });

  group('custom options', () {
    test('custom options appear in build output', () {
      final s = ConnectionStringBuilder()
          .server('h')
          .option('Encrypt', 'yes')
          .option('TrustServerCertificate', 'yes')
          .build();
      expect(s, contains('Encrypt=yes'));
      expect(s, contains('TrustServerCertificate=yes'));
    });
  });
}

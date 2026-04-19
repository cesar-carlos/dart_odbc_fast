import 'package:odbc_fast/domain/builders/connection_string_builder.dart';
import 'package:test/test.dart';

void main() {
  group('v3.0 ConnectionStringBuilder variants', () {
    test('MariaDbBuilder uses MariaDB driver and port 3306', () {
      final cs = MariaDbBuilder()
          .server('db.example.com')
          .database('app')
          .credentials('user', 'pwd')
          .build();
      expect(cs, contains('Driver={MariaDB ODBC 3.1 Driver}'));
      expect(cs, contains('Port=3306'));
      expect(cs, contains('Server=db.example.com'));
      expect(cs, contains('Database=app'));
    });

    test('SqliteBuilder uses SQLite driver and file path', () {
      final cs = SqliteBuilder().database('/tmp/local.db').build();
      expect(cs, contains('Driver={SQLite3 ODBC Driver}'));
      expect(cs, contains('Database=/tmp/local.db'));
      // SQLite has no Server/Port default.
      expect(cs.contains('Server='), isFalse);
    });

    test('Db2Builder uses Db2 driver and port 50000', () {
      final cs = Db2Builder()
          .server('db2.example.com')
          .database('SAMPLE')
          .credentials('db2inst', 'secret')
          .build();
      expect(cs, contains('Driver={IBM DB2 ODBC DRIVER}'));
      expect(cs, contains('Port=50000'));
      expect(cs, contains('Database=SAMPLE'));
    });

    test('SnowflakeBuilder uses Snowflake driver', () {
      final cs = SnowflakeBuilder()
          .server('acct.snowflakecomputing.com')
          .credentials('user', 'pwd')
          .option('Database', 'PROD')
          .option('Warehouse', 'COMPUTE_WH')
          .option('Role', 'ANALYST')
          .build();
      expect(cs, contains('Driver={SnowflakeDSIIDriver}'));
      expect(cs, contains('Server=acct.snowflakecomputing.com'));
      expect(cs, contains('Database=PROD'));
      expect(cs, contains('Warehouse=COMPUTE_WH'));
      expect(cs, contains('Role=ANALYST'));
    });
  });
}

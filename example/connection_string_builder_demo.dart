// Connection string builder demo (no database required).
// Run: dart run example/connection_string_builder_demo.dart
//
// Showcases all seven builders shipped by the package: three v1 (SQL Server,
// PostgreSQL, MySQL) and four added in v3.0 (MariaDB, SQLite, Db2, Snowflake).

import 'package:odbc_fast/odbc_fast.dart';

void main() {
  AppLogger.initialize();

  AppLogger.info('--- v1 builders -------------------------------------');

  final sqlServer = SqlServerBuilder()
      .server('localhost')
      .port(1433)
      .database('MyDB')
      .credentials('user', 'pass')
      .option('Encrypt', 'yes')
      .option('TrustServerCertificate', 'yes')
      .build();
  AppLogger.info('SQL Server : $sqlServer');

  final postgres = PostgreSqlBuilder()
      .server('localhost')
      .database('app_db')
      .credentials('postgres', 'secret')
      .build();
  AppLogger.info('PostgreSQL : $postgres');

  final mysql = MySqlBuilder()
      .server('localhost')
      .database('shop')
      .credentials('root', 'secret')
      .build();
  AppLogger.info('MySQL      : $mysql');

  final trustedSqlServer =
      SqlServerBuilder().server('localhost').database('MyDB').trusted().build();
  AppLogger.info('Trusted SQL: $trustedSqlServer');

  AppLogger.info('--- v3.0 builders -----------------------------------');

  final mariadb = MariaDbBuilder()
      .server('db.example.com')
      .database('app')
      .credentials('user', 'pwd')
      .build();
  AppLogger.info('MariaDB    : $mariadb');

  final sqlite = SqliteBuilder().database('/tmp/local.db').build();
  AppLogger.info('SQLite     : $sqlite');

  final db2 = Db2Builder()
      .server('db2.example.com')
      .database('SAMPLE')
      .credentials('db2inst', 'secret')
      .build();
  AppLogger.info('IBM Db2    : $db2');

  final snowflake = SnowflakeBuilder()
      .server('acct.snowflakecomputing.com')
      .credentials('user', 'pwd')
      .option('Database', 'PROD')
      .option('Warehouse', 'COMPUTE_WH')
      .option('Role', 'ANALYST')
      .build();
  AppLogger.info('Snowflake  : $snowflake');
}

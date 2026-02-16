// Connection string builder demo (no database required).
// Run: dart run example/connection_string_builder_demo.dart

import 'package:odbc_fast/odbc_fast.dart';

void main() {
  AppLogger.initialize();

  final sqlServer = SqlServerBuilder()
      .server('localhost')
      .port(1433)
      .database('MyDB')
      .credentials('user', 'pass')
      .option('Encrypt', 'yes')
      .option('TrustServerCertificate', 'yes')
      .build();

  final postgres = PostgreSqlBuilder()
      .server('localhost')
      .database('app_db')
      .credentials('postgres', 'secret')
      .build();

  final mysql = MySqlBuilder()
      .server('localhost')
      .database('shop')
      .credentials('root', 'secret')
      .build();

  final trustedSqlServer =
      SqlServerBuilder().server('localhost').database('MyDB').trusted().build();

  AppLogger.info('SQL Server  : $sqlServer');
  AppLogger.info('PostgreSQL  : $postgres');
  AppLogger.info('MySQL       : $mysql');
  AppLogger.info('Trusted auth: $trustedSqlServer');
}

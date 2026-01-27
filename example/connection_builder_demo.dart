import 'package:odbc_fast/odbc_fast.dart';

/// Connection string builder demo: build ODBC connection strings with a fluent DSL.
///
/// Run: dart run example/connection_builder_demo.dart
void main() {
  print('=== ODBC Fast - Connection String Builder Demo ===\n');

  final sqlServer = SqlServerBuilder()
      .server('localhost')
      .database('AdventureWorks')
      .credentials('sa', 'secret')
      .build();
  print('SQL Server: $sqlServer');

  final postgres = PostgreSqlBuilder()
      .server('localhost')
      .port(5432)
      .database('testdb')
      .credentials('postgres', 'pw')
      .build();
  print('PostgreSQL: $postgres');

  final mysql = MySqlBuilder()
      .server('localhost')
      .database('mydb')
      .credentials('root', 'pw')
      .build();
  print('MySQL: $mysql');

  final trusted = SqlServerBuilder()
      .server('localhost')
      .database('MyDb')
      .trusted()
      .option('Encrypt', 'yes')
      .build();
  print('SQL Server (trusted + Encrypt): $trusted');

  print('\nUse these strings with service.connect(connectionString).');
}

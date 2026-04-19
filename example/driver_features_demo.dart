// Driver-specific SQL builders (v3.0).
// Run: dart run example/driver_features_demo.dart
//
// Pure SQL generation — no database required. Demonstrates the v3.0
// `OdbcDriverFeatures` API: UPSERT, RETURNING/OUTPUT, and per-engine
// session initialization.

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities_v3.dart';
import 'package:odbc_fast/odbc_fast.dart';

void main() {
  AppLogger.initialize();

  final native = OdbcNative();
  if (!native.init()) {
    AppLogger.severe('odbc_init failed');
    return;
  }

  final features = OdbcDriverFeatures(native);
  if (!features.supportsApi) {
    AppLogger.warning('Native lib does not expose v3.0 capability FFIs');
    native.dispose();
    return;
  }

  // Example connection strings per engine — only the Driver/server tokens
  // matter for dialect detection; no actual connect happens.
  const connectionStrings = <String, String>{
    'PostgreSQL': 'Driver={PostgreSQL Unicode};Server=db;Database=app',
    'MySQL': 'Driver={MySQL ODBC 8.0 Driver};Server=db;Database=app',
    'MariaDB': 'Driver={MariaDB ODBC 3.1 Driver};Server=db;Database=app',
    'SQL Server': 'Driver={SQL Server};Server=db;Database=app',
    'Oracle': 'Driver={Oracle in OraClient19Home1};DBQ=db',
    'SQLite': 'Driver={SQLite3 ODBC Driver};Database=/tmp/app.db',
    'Db2': 'Driver={IBM DB2 ODBC DRIVER};Database=APP',
    'Snowflake':
        'Driver={SnowflakeDSIIDriver};Server=acct.snowflakecomputing.com',
  };

  AppLogger.info('=== UPSERT per dialect ===');
  for (final entry in connectionStrings.entries) {
    final sql = features.buildUpsertSql(
      connectionString: entry.value,
      table: 'users',
      columns: const ['id', 'name', 'email'],
      conflictColumns: const ['id'],
    );
    AppLogger.info(
      '${entry.key.padRight(11)} => ${sql ?? "(unsupported / no plugin)"}',
    );
  }

  AppLogger.info('');
  AppLogger.info('=== RETURNING / OUTPUT per dialect ===');
  const insertSql = 'INSERT INTO users (name, email) VALUES (?, ?)';
  for (final entry in connectionStrings.entries) {
    final sql = features.appendReturningClause(
      connectionString: entry.value,
      sql: insertSql,
      verb: DmlVerb.insert,
      columns: const ['id', 'created_at'],
    );
    AppLogger.info('${entry.key.padRight(11)} => ${sql ?? "(unsupported)"}');
  }

  AppLogger.info('');
  AppLogger.info('=== Session init SQL per dialect ===');
  const sessionOpts = SessionOptions(
    applicationName: 'odbc_fast_demo',
    timezone: 'UTC',
    schema: 'public',
    charset: 'utf8mb4',
  );
  for (final entry in connectionStrings.entries) {
    final stmts = features.getSessionInitSql(
      connectionString: entry.value,
      options: sessionOpts,
    );
    AppLogger.info('-- ${entry.key} --');
    if (stmts == null || stmts.isEmpty) {
      AppLogger.info('   (no specific session init)');
    } else {
      for (final s in stmts) {
        AppLogger.info(
          '   ${s.length > 110 ? "${s.substring(0, 107)}..." : s}',
        );
      }
    }
  }

  native.dispose();
}

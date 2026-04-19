// Live DBMS introspection via SQLGetInfo (v2.1).
// Run: dart run example/dbms_info_demo.dart
//
// Connects to the configured `ODBC_TEST_DSN`, then asks the live driver
// who it is via `odbc_get_connection_dbms_info`. More accurate than
// parsing the connection string: works for DSN-only strings and
// distinguishes MariaDB from MySQL, ASE from ASA, etc.

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities.dart';
import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

void main() {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final native = OdbcNative();
  if (!native.init()) {
    AppLogger.severe('odbc_init failed');
    return;
  }

  final caps = OdbcDriverCapabilities(native);
  if (!caps.supportsApi) {
    AppLogger.warning('Native lib does not expose v2.1+ DBMS introspection');
    native.dispose();
    return;
  }

  final connId = native.connect(dsn);
  if (connId == 0) {
    AppLogger.severe('connect failed: ${native.getError()}');
    native.dispose();
    return;
  }

  try {
    final info = caps.getDbmsInfoForConnection(connId);
    if (info == null) {
      AppLogger.warning('No DBMS info available');
      return;
    }

    AppLogger.info('--- DbmsInfo from live SQLGetInfo ----------------');
    AppLogger.info('dbmsName            : ${info.dbmsName}');
    AppLogger.info('engineId (canonical): ${info.engineId}');
    AppLogger.info('databaseType (Dart) : ${info.databaseType}');
    AppLogger.info('maxCatalogNameLen   : ${info.maxCatalogNameLen}');
    AppLogger.info('maxSchemaNameLen    : ${info.maxSchemaNameLen}');
    AppLogger.info('maxTableNameLen     : ${info.maxTableNameLen}');
    AppLogger.info('maxColumnNameLen    : ${info.maxColumnNameLen}');
    AppLogger.info('currentCatalog      : "${info.currentCatalog}"');

    AppLogger.info('--- Embedded driver capabilities -----------------');
    final c = info.capabilities;
    AppLogger.info('driverName    : ${c.driverName}');
    AppLogger.info('driverVersion : ${c.driverVersion}');
    AppLogger.info('engineId      : ${c.engineId}');
    AppLogger.info('databaseType  : ${c.databaseType}');
    AppLogger.info('maxArraySize  : ${c.maxRowArraySize}');
    AppLogger.info('supports prep : ${c.supportsPreparedStatements}');
    AppLogger.info('supports batch: ${c.supportsBatchOperations}');
    AppLogger.info('supports strm : ${c.supportsStreaming}');

    AppLogger.info('--- Switch on canonical engine id ----------------');
    switch (info.databaseType) {
      case DatabaseType.sqlServer:
        AppLogger.info(
          'Use [brackets] quoting and OUTPUT INSERTED.* for RETURNING.',
        );
      case DatabaseType.postgresql:
        AppLogger.info('Use "double quotes" and ON CONFLICT for UPSERT.');
      case DatabaseType.mariadb:
        AppLogger.info('MariaDB supports RETURNING (since 10.5).');
      case DatabaseType.mysql:
        AppLogger.info('MySQL: no RETURNING; use SELECT LAST_INSERT_ID().');
      case DatabaseType.oracle:
        AppLogger.info('Oracle: RETURNING ... INTO :var (OUT bind).');
      case DatabaseType.sqlite:
        AppLogger.info('SQLite: ON CONFLICT + RETURNING (3.35+).');
      case DatabaseType.db2:
        AppLogger.info('Db2: SELECT ... FROM FINAL TABLE for RETURNING.');
      case DatabaseType.snowflake:
        AppLogger.info('Snowflake: MERGE + RETURNING.');
      case DatabaseType.sybaseAse:
      case DatabaseType.sybaseAsa:
        AppLogger.info('Sybase: SAVE TRANSACTION savepoint dialect.');
      case DatabaseType.mongodb:
      case DatabaseType.redshift:
      case DatabaseType.bigquery:
      case DatabaseType.unknown:
        AppLogger.info('Engine without dedicated v3.0 plugin.');
    }
  } finally {
    native
      ..disconnect(connId)
      ..dispose();
  }
}

// Live DBMS introspection via the high-level service API.
//
// Connects with `ServiceLocator`, then calls `getConnectionDbmsInfo`
// (`SQLGetInfo` under the hood). More accurate than parsing the connection
// string: works for DSN-only strings and distinguishes MariaDB from MySQL,
// ASE from ASA, etc.
//
// Run: dart run example/dbms_info_demo.dart

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

void main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final locator = ServiceLocator()..initialize();
  final service = locator.syncService;

  final init = await service.initialize();
  if (init.isError()) {
    AppLogger.severe('initialize failed: ${init.exceptionOrNull()}');
    return;
  }

  final connResult = await service.connect(dsn);
  final conn = connResult.getOrNull();
  if (conn == null) {
    AppLogger.severe('connect failed: ${connResult.exceptionOrNull()}');
    locator.shutdown();
    return;
  }

  try {
    final infoResult = await service.getConnectionDbmsInfo(conn.id);
    final info = infoResult.getOrNull();
    if (info == null) {
      AppLogger.warning(
        'getConnectionDbmsInfo unavailable: ${infoResult.exceptionOrNull()}',
      );
      return;
    }

    AppLogger.info('--- DbmsInfo from live SQLGetInfo ----------------');
    AppLogger.info('dbmsName            : ${info.dbmsName}');
    AppLogger.info('dbmsVersion         : ${info.dbmsVersion}');
    AppLogger.info('engineId (canonical): ${info.engineId}');
    AppLogger.info('databaseType (Dart) : ${info.databaseType}');
    AppLogger.info('maxCatalogNameLen   : ${info.maxCatalogNameLen}');
    AppLogger.info('maxSchemaNameLen    : ${info.maxSchemaNameLen}');
    AppLogger.info('maxTableNameLen     : ${info.maxTableNameLen}');
    AppLogger.info('maxColumnNameLen    : ${info.maxColumnNameLen}');
    AppLogger.info('currentCatalog      : "${info.currentCatalog}"');

    AppLogger.info('--- Embedded driver capabilities -----------------');
    final caps = info.capabilities;
    AppLogger.info('driverName    : ${caps.driverName}');
    AppLogger.info('driverVersion : ${caps.driverVersion}');
    AppLogger.info('engineId      : ${caps.engineId}');
    AppLogger.info('databaseType  : ${caps.databaseType}');
    AppLogger.info('maxArraySize  : ${caps.maxRowArraySize}');
    AppLogger.info('supports prep : ${caps.supportsPreparedStatements}');
    AppLogger.info('supports batch: ${caps.supportsBatchOperations}');
    AppLogger.info('supports strm : ${caps.supportsStreaming}');

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
    await service.disconnect(conn.id);
    locator.shutdown();
  }
}

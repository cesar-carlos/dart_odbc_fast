/// Canonical engine identifier returned by the Rust layer
/// (`engine::core::ENGINE_*`). Stable across releases.
class DatabaseEngineIds {
  DatabaseEngineIds._();

  static const String sqlserver = 'sqlserver';
  static const String postgres = 'postgres';
  static const String mysql = 'mysql';
  static const String mariadb = 'mariadb';
  static const String oracle = 'oracle';
  static const String sybaseAse = 'sybase_ase';
  static const String sybaseAsa = 'sybase_asa';
  static const String sqlite = 'sqlite';
  static const String db2 = 'db2';
  static const String snowflake = 'snowflake';
  static const String redshift = 'redshift';
  static const String bigquery = 'bigquery';
  static const String mongodb = 'mongodb';
  static const String unknown = 'unknown';
}

/// Logical database family. Use [DatabaseType.fromEngineId] when you have a
/// canonical engine id from the native layer (preferred); fall back to
/// [DatabaseType.fromDriverName] only for legacy callers that only have the
/// raw driver name.
enum DatabaseType {
  sqlServer,
  postgresql,
  mysql,
  mariadb,
  sqlite,
  oracle,
  sybaseAse,
  sybaseAsa,
  db2,
  snowflake,
  redshift,
  bigquery,
  mongodb,
  unknown;

  /// Map a canonical engine id (`engine::core::ENGINE_*`) to a [DatabaseType].
  /// Use this when reading the `engine` field from
  /// `odbc_get_connection_dbms_info` or `odbc_get_driver_capabilities`.
  static DatabaseType fromEngineId(String engineId) {
    switch (engineId) {
      case DatabaseEngineIds.sqlserver:
        return DatabaseType.sqlServer;
      case DatabaseEngineIds.postgres:
        return DatabaseType.postgresql;
      case DatabaseEngineIds.mysql:
        return DatabaseType.mysql;
      case DatabaseEngineIds.mariadb:
        return DatabaseType.mariadb;
      case DatabaseEngineIds.oracle:
        return DatabaseType.oracle;
      case DatabaseEngineIds.sybaseAse:
        return DatabaseType.sybaseAse;
      case DatabaseEngineIds.sybaseAsa:
        return DatabaseType.sybaseAsa;
      case DatabaseEngineIds.sqlite:
        return DatabaseType.sqlite;
      case DatabaseEngineIds.db2:
        return DatabaseType.db2;
      case DatabaseEngineIds.snowflake:
        return DatabaseType.snowflake;
      case DatabaseEngineIds.redshift:
        return DatabaseType.redshift;
      case DatabaseEngineIds.bigquery:
        return DatabaseType.bigquery;
      case DatabaseEngineIds.mongodb:
        return DatabaseType.mongodb;
      default:
        return DatabaseType.unknown;
    }
  }

  /// Heuristic mapping from a driver / DBMS name. Less accurate than
  /// [fromEngineId]; kept for backwards compatibility.
  ///
  /// Keep in sync with Rust `DriverCapabilities::engine_from_name`.
  static DatabaseType fromDriverName(String driverName) {
    final lower = driverName.trim().toLowerCase();
    if (lower.contains('sql anywhere') ||
        lower.contains('adaptive server anywhere') ||
        (lower.contains('asa') &&
            (lower.contains('sybase') || lower.contains('sql anywhere')))) {
      return DatabaseType.sybaseAsa;
    }
    if (lower.contains('adaptive server enterprise') ||
        (lower.contains('ase') &&
            (lower.contains('sybase') || lower.contains('adaptive')))) {
      return DatabaseType.sybaseAse;
    }
    if (lower.contains('sybase')) {
      return DatabaseType.sybaseAse;
    }
    if (lower.contains('mariadb')) {
      return DatabaseType.mariadb;
    }
    if (lower.contains('microsoft sql server') ||
        lower.contains('sql server') ||
        lower.contains('mssql') ||
        lower == 'sqlserver' ||
        lower.contains('sqlsrv32')) {
      return DatabaseType.sqlServer;
    }
    if (lower.contains('postgresql') || lower.contains('postgres')) {
      return DatabaseType.postgresql;
    }
    if (lower.contains('mysql')) {
      return DatabaseType.mysql;
    }
    if (lower.contains('oracle')) {
      return DatabaseType.oracle;
    }
    if (lower.contains('sqlite')) {
      return DatabaseType.sqlite;
    }
    if (lower.contains('db2')) {
      return DatabaseType.db2;
    }
    if (lower.contains('snowflake')) {
      return DatabaseType.snowflake;
    }
    if (lower.contains('redshift')) {
      return DatabaseType.redshift;
    }
    if (lower.contains('bigquery')) {
      return DatabaseType.bigquery;
    }
    if (lower.contains('mongodb')) {
      return DatabaseType.mongodb;
    }
    return DatabaseType.unknown;
  }
}

/// Typed driver capabilities parsed from native JSON payload.
///
/// Boolean flags and [maxRowArraySize] are a canonical table per engine, not
/// live `SQLGetInfo` probes. On the live path, [driverName] / [driverVersion]
/// come from `SQL_DRIVER_NAME` / `SQL_DRIVER_VER`.
class DriverCapabilities {
  const DriverCapabilities({
    required this.supportsPreparedStatements,
    required this.supportsBatchOperations,
    required this.supportsStreaming,
    required this.maxRowArraySize,
    required this.driverName,
    required this.driverVersion,
    required this.databaseType,
    required this.engineId,
    required this.supportsNativeBcp,
  });

  final bool supportsPreparedStatements;
  final bool supportsBatchOperations;
  final bool supportsStreaming;
  final int maxRowArraySize;
  final String driverName;
  final String driverVersion;
  final DatabaseType databaseType;
  final String engineId;

  /// Whether the native engine was built with `sqlserver-bcp` on Windows for
  /// this engine. Does not imply `ODBC_ENABLE_UNSTABLE_NATIVE_BCP` is set.
  final bool supportsNativeBcp;
}

/// Live DBMS introspection (NEW in v2.1). Populated by
/// `odbc_get_connection_dbms_info` once the connection is open.
class DbmsInfo {
  const DbmsInfo({
    required this.dbmsName,
    required this.engineId,
    required this.databaseType,
    required this.maxCatalogNameLen,
    required this.maxSchemaNameLen,
    required this.maxTableNameLen,
    required this.maxColumnNameLen,
    required this.currentCatalog,
    required this.capabilities,
    this.dbmsVersion = '',
  });

  /// Server-reported `SQL_DBMS_NAME` (e.g. `"Microsoft SQL Server"`,
  /// `"PostgreSQL"`, `"MariaDB"`, `"Adaptive Server Anywhere"`).
  final String dbmsName;

  /// Server-reported `SQL_DBMS_VER` (empty when the driver omits it).
  final String dbmsVersion;

  /// Canonical engine id (one of [DatabaseEngineIds]).
  final String engineId;

  /// Logical database family (preferred over [dbmsName] for switch/case).
  final DatabaseType databaseType;

  final int maxCatalogNameLen;
  final int maxSchemaNameLen;
  final int maxTableNameLen;
  final int maxColumnNameLen;

  /// Currently selected catalog/database (empty if not applicable).
  final String currentCatalog;

  /// Capabilities for this engine. Flags / [DriverCapabilities.maxRowArraySize]
  /// are canonical; driver name/version are live on this path.
  final DriverCapabilities capabilities;
}

import 'dart:convert';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';

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
  static DatabaseType fromDriverName(String driverName) {
    final normalized = driverName.toLowerCase();
    if (normalized.contains('mariadb')) {
      return DatabaseType.mariadb;
    }
    if (normalized.contains('microsoft sql server') ||
        normalized.contains('sql server') ||
        normalized.contains('sqlserver') ||
        normalized.contains('mssql')) {
      return DatabaseType.sqlServer;
    }
    if (normalized.contains('postgres') || normalized.contains('postgresql')) {
      return DatabaseType.postgresql;
    }
    if (normalized.contains('mysql')) {
      return DatabaseType.mysql;
    }
    if (normalized.contains('sqlite')) {
      return DatabaseType.sqlite;
    }
    if (normalized.contains('oracle')) {
      return DatabaseType.oracle;
    }
    if (normalized.contains('adaptive server anywhere') ||
        normalized.contains('sql anywhere')) {
      return DatabaseType.sybaseAsa;
    }
    if (normalized.contains('adaptive server enterprise') ||
        normalized.contains('sybase')) {
      return DatabaseType.sybaseAse;
    }
    if (normalized.contains('db2')) {
      return DatabaseType.db2;
    }
    if (normalized.contains('snowflake')) {
      return DatabaseType.snowflake;
    }
    if (normalized.contains('redshift')) {
      return DatabaseType.redshift;
    }
    if (normalized.contains('bigquery')) {
      return DatabaseType.bigquery;
    }
    if (normalized.contains('mongodb')) {
      return DatabaseType.mongodb;
    }
    return DatabaseType.unknown;
  }
}

/// Typed driver capabilities parsed from native JSON payload.
class DriverCapabilities {
  DriverCapabilities({
    required this.supportsPreparedStatements,
    required this.supportsBatchOperations,
    required this.supportsStreaming,
    required this.maxRowArraySize,
    required this.driverName,
    required this.driverVersion,
    required this.databaseType,
    required this.engineId,
  });

  factory DriverCapabilities.fromJson(Map<String, Object?> json) {
    final driverName = json['driver_name'] as String? ?? 'Unknown';
    final engineId = json['engine'] as String? ?? DatabaseEngineIds.unknown;
    // Prefer canonical id from the native layer; fall back to
    // driver-name heuristic when the field is missing/unknown.
    final databaseType = engineId == DatabaseEngineIds.unknown
        ? DatabaseType.fromDriverName(driverName)
        : DatabaseType.fromEngineId(engineId);
    return DriverCapabilities(
      supportsPreparedStatements:
          json['supports_prepared_statements'] as bool? ?? true,
      supportsBatchOperations:
          json['supports_batch_operations'] as bool? ?? true,
      supportsStreaming: json['supports_streaming'] as bool? ?? true,
      maxRowArraySize: (json['max_row_array_size'] as num?)?.toInt() ?? 1000,
      driverName: driverName,
      driverVersion: json['driver_version'] as String? ?? 'Unknown',
      databaseType: databaseType,
      engineId: engineId,
    );
  }

  final bool supportsPreparedStatements;
  final bool supportsBatchOperations;
  final bool supportsStreaming;
  final int maxRowArraySize;
  final String driverName;
  final String driverVersion;
  final DatabaseType databaseType;
  final String engineId;
}

/// Live DBMS introspection (NEW in v2.1). Populated by
/// `odbc_get_connection_dbms_info` once the connection is open.
class DbmsInfo {
  DbmsInfo({
    required this.dbmsName,
    required this.engineId,
    required this.databaseType,
    required this.maxCatalogNameLen,
    required this.maxSchemaNameLen,
    required this.maxTableNameLen,
    required this.maxColumnNameLen,
    required this.currentCatalog,
    required this.capabilities,
  });

  factory DbmsInfo.fromJson(Map<String, Object?> json) {
    final dbmsName = json['dbms_name'] as String? ?? 'Unknown';
    final engineId = json['engine'] as String? ?? DatabaseEngineIds.unknown;
    final caps = json['capabilities'];
    final capabilities = caps is Map<String, Object?>
        ? DriverCapabilities.fromJson(caps)
        : DriverCapabilities(
            supportsPreparedStatements: true,
            supportsBatchOperations: true,
            supportsStreaming: true,
            maxRowArraySize: 1000,
            driverName: dbmsName,
            driverVersion: 'Unknown',
            databaseType: DatabaseType.fromEngineId(engineId),
            engineId: engineId,
          );
    return DbmsInfo(
      dbmsName: dbmsName,
      engineId: engineId,
      databaseType: DatabaseType.fromEngineId(engineId),
      maxCatalogNameLen: (json['max_catalog_name_len'] as num?)?.toInt() ?? 0,
      maxSchemaNameLen: (json['max_schema_name_len'] as num?)?.toInt() ?? 0,
      maxTableNameLen: (json['max_table_name_len'] as num?)?.toInt() ?? 0,
      maxColumnNameLen: (json['max_column_name_len'] as num?)?.toInt() ?? 0,
      currentCatalog: json['current_catalog'] as String? ?? '',
      capabilities: capabilities,
    );
  }

  /// Server-reported `SQL_DBMS_NAME` (e.g. `"Microsoft SQL Server"`,
  /// `"PostgreSQL"`, `"MariaDB"`, `"Adaptive Server Anywhere"`).
  final String dbmsName;

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

  /// Capabilities derived from the live DBMS name.
  final DriverCapabilities capabilities;
}

/// Typed wrapper for native driver capabilities FFI.
class OdbcDriverCapabilities {
  OdbcDriverCapabilities(this._native);

  final OdbcNative _native;

  /// Whether the loaded native library exposes driver capabilities API.
  bool get supportsApi => _native.supportsDriverCapabilitiesApi;

  /// Heuristic capabilities derived from a connection string (fast, no I/O).
  /// Prefer [getDbmsInfoForConnection] when the connection is already open.
  DriverCapabilities? getCapabilities(String connectionString) {
    final payload = _native.getDriverCapabilitiesJson(connectionString);
    if (payload == null || payload.isEmpty) {
      return null;
    }
    final dynamic decoded = jsonDecode(payload);
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    return DriverCapabilities.fromJson(decoded);
  }

  /// Live DBMS introspection (v2.1). Returns [DbmsInfo] for the open
  /// connection identified by [connectionId], or `null` if the native
  /// library does not expose the new entry point or the call fails.
  DbmsInfo? getDbmsInfoForConnection(int connectionId) {
    final payload = _native.getConnectionDbmsInfoJson(connectionId);
    if (payload == null || payload.isEmpty) {
      return null;
    }
    final dynamic decoded = jsonDecode(payload);
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    return DbmsInfo.fromJson(decoded);
  }
}

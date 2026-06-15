import 'package:odbc_fast/domain/entities/driver_capabilities.dart';

/// Maps native JSON payloads to domain [DriverCapabilities] and [DbmsInfo].
///
/// Keeps JSON parsing at the infrastructure boundary so domain entities stay
/// pure value objects.
class DriverCapabilitiesMapper {
  DriverCapabilitiesMapper._();

  /// Parses a driver-capabilities JSON map from the native layer.
  static DriverCapabilities fromJson(Map<String, Object?> json) {
    final driverName = json['driver_name'] as String? ?? 'Unknown';
    final engineId = json['engine'] as String? ?? DatabaseEngineIds.unknown;
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
      supportsNativeBcp: json['supports_native_bcp'] as bool? ?? false,
    );
  }

  /// Parses live DBMS introspection JSON from `odbc_get_connection_dbms_info`.
  static DbmsInfo dbmsInfoFromJson(Map<String, Object?> json) {
    final dbmsName = json['dbms_name'] as String? ?? 'Unknown';
    final engineId = json['engine'] as String? ?? DatabaseEngineIds.unknown;
    final caps = json['capabilities'];
    final capabilities = caps is Map<String, Object?>
        ? fromJson(caps)
        : DriverCapabilities(
            supportsPreparedStatements: true,
            supportsBatchOperations: true,
            supportsStreaming: true,
            maxRowArraySize: 1000,
            driverName: dbmsName,
            driverVersion: 'Unknown',
            databaseType: DatabaseType.fromEngineId(engineId),
            engineId: engineId,
            supportsNativeBcp: false,
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
}

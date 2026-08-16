import 'package:odbc_fast/domain/entities/driver_capabilities.dart';

/// Maps native JSON payloads to domain [DriverCapabilities] and [DbmsInfo].
///
/// Keeps JSON parsing at the infrastructure boundary so domain entities stay
/// pure value objects.
class DriverCapabilitiesMapper {
  DriverCapabilitiesMapper._();

  /// Normalizes `jsonDecode` maps (`Map<String, dynamic>`) into
  /// `Map<String, Object?>`, including nested objects.
  static Map<String, Object?>? asJsonMap(Object? value) {
    if (value is! Map) {
      return null;
    }
    return value.map<String, Object?>(
      (key, nested) => MapEntry(key.toString(), _normalizeJsonValue(nested)),
    );
  }

  static Object? _normalizeJsonValue(Object? value) {
    if (value is Map) {
      return asJsonMap(value);
    }
    if (value is List) {
      return value.map(_normalizeJsonValue).toList();
    }
    return value;
  }

  /// Parses a driver-capabilities JSON map from the native layer.
  ///
  /// [DatabaseType] is taken only from the canonical `engine` field. An
  /// unknown engine stays [DatabaseType.unknown] even if `driver_name` would
  /// match the legacy heuristic.
  static DriverCapabilities fromJson(Map<String, Object?> json) {
    final driverName = json['driver_name'] as String? ?? 'Unknown';
    final engineId = json['engine'] as String? ?? DatabaseEngineIds.unknown;
    return DriverCapabilities(
      supportsPreparedStatements:
          json['supports_prepared_statements'] as bool? ?? true,
      supportsBatchOperations:
          json['supports_batch_operations'] as bool? ?? true,
      supportsStreaming: json['supports_streaming'] as bool? ?? true,
      maxRowArraySize: (json['max_row_array_size'] as num?)?.toInt() ?? 1000,
      driverName: driverName,
      driverVersion: json['driver_version'] as String? ?? 'Unknown',
      databaseType: DatabaseType.fromEngineId(engineId),
      engineId: engineId,
      supportsNativeBcp: json['supports_native_bcp'] as bool? ?? false,
    );
  }

  /// Parses live DBMS introspection JSON from `odbc_get_connection_dbms_info`.
  static DbmsInfo dbmsInfoFromJson(Map<String, Object?> json) {
    final dbmsName = json['dbms_name'] as String? ?? 'Unknown';
    final engineId = json['engine'] as String? ?? DatabaseEngineIds.unknown;
    final capsMap = asJsonMap(json['capabilities']);
    final capabilities = capsMap != null
        ? fromJson(capsMap)
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
      dbmsVersion: json['dbms_version'] as String? ?? '',
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

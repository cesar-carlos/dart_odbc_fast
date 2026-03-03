import 'dart:convert';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';

/// Typed driver capabilities parsed from native JSON payload.
class DriverCapabilities {
  DriverCapabilities({
    required this.supportsPreparedStatements,
    required this.supportsBatchOperations,
    required this.supportsStreaming,
    required this.maxRowArraySize,
    required this.driverName,
    required this.driverVersion,
  });

  factory DriverCapabilities.fromJson(Map<String, Object?> json) {
    return DriverCapabilities(
      supportsPreparedStatements:
          json['supports_prepared_statements'] as bool? ?? true,
      supportsBatchOperations:
          json['supports_batch_operations'] as bool? ?? true,
      supportsStreaming: json['supports_streaming'] as bool? ?? true,
      maxRowArraySize: (json['max_row_array_size'] as num?)?.toInt() ?? 1000,
      driverName: json['driver_name'] as String? ?? 'Unknown',
      driverVersion: json['driver_version'] as String? ?? 'Unknown',
    );
  }

  final bool supportsPreparedStatements;
  final bool supportsBatchOperations;
  final bool supportsStreaming;
  final int maxRowArraySize;
  final String driverName;
  final String driverVersion;
}

/// Typed wrapper for native driver capabilities FFI.
class OdbcDriverCapabilities {
  OdbcDriverCapabilities(this._native);

  final OdbcNative _native;

  /// Whether the loaded native library exposes driver capabilities API.
  bool get supportsApi => _native.supportsDriverCapabilitiesApi;

  /// Returns parsed capabilities from [connectionString], or null when
  /// unavailable or invalid.
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
}

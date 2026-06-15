import 'dart:convert';

import 'package:odbc_fast/domain/entities/driver_capabilities.dart';
import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities_mapper.dart';

export 'package:odbc_fast/domain/entities/driver_capabilities.dart';

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
    return DriverCapabilitiesMapper.fromJson(decoded);
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
    return DriverCapabilitiesMapper.dbmsInfoFromJson(decoded);
  }
}

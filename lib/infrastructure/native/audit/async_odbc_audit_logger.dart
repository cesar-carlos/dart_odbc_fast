import 'dart:convert';

import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/audit/odbc_audit_logger.dart';

/// Async typed wrapper around audit operations executed in worker isolate.
class AsyncOdbcAuditLogger {
  /// Creates async typed logger bound to [connection].
  AsyncOdbcAuditLogger(AsyncNativeOdbcConnection connection)
      : _setEnabled = connection.setAuditEnabled,
        _clear = connection.clearAuditEvents,
        _getEventsJson = connection.getAuditEventsJson,
        _getStatusJson = connection.getAuditStatusJson;

  /// Creates an instance with injected delegates for tests.
  AsyncOdbcAuditLogger.forTesting({
    required Future<bool> Function({required bool enabled}) setEnabled,
    required Future<bool> Function() clear,
    required Future<String?> Function({int limit}) getEventsJson,
    required Future<String?> Function() getStatusJson,
  })  : _setEnabled = setEnabled,
        _clear = clear,
        _getEventsJson = getEventsJson,
        _getStatusJson = getStatusJson;

  final Future<bool> Function({required bool enabled}) _setEnabled;
  final Future<bool> Function() _clear;
  final Future<String?> Function({int limit}) _getEventsJson;
  final Future<String?> Function() _getStatusJson;

  /// Enables native audit collection.
  Future<bool> enable() => _setEnabled(enabled: true);

  /// Disables native audit collection.
  Future<bool> disable() => _setEnabled(enabled: false);

  /// Clears all in-memory native audit events.
  Future<bool> clear() => _clear();

  /// Returns parsed audit status, or `null` when unavailable/invalid.
  Future<OdbcAuditStatus?> getStatus() async {
    final payload = await _getStatusJson();
    if (payload == null || payload.isEmpty) {
      return null;
    }
    final dynamic decoded = jsonDecode(payload);
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    return OdbcAuditStatus.fromJson(decoded);
  }

  /// Returns parsed audit events.
  ///
  /// When [limit] is `0`, native default behavior is used.
  Future<List<OdbcAuditEvent>> getEvents({int limit = 0}) async {
    final payload = await _getEventsJson(limit: limit);
    if (payload == null || payload.isEmpty) {
      return <OdbcAuditEvent>[];
    }

    final dynamic decoded = jsonDecode(payload);
    if (decoded is! List<dynamic>) {
      return <OdbcAuditEvent>[];
    }

    return decoded
        .whereType<Map<String, Object?>>()
        .map(OdbcAuditEvent.fromJson)
        .toList(growable: false);
  }
}

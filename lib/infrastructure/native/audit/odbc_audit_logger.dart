import 'dart:convert';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';

/// Typed audit event mapped from native JSON payloads.
class OdbcAuditEvent {
  /// Creates an [OdbcAuditEvent].
  OdbcAuditEvent({
    required this.timestampMs,
    required this.eventType,
    required this.connectionId,
    required this.query,
    required this.metadata,
  });

  /// Builds an [OdbcAuditEvent] from a decoded JSON map.
  factory OdbcAuditEvent.fromJson(Map<String, Object?> json) {
    final dynamic metadataRaw = json['metadata'];
    final normalizedMetadata = <String, String>{};
    if (metadataRaw is Map<String, Object?>) {
      metadataRaw.forEach((key, value) {
        normalizedMetadata[key] = value?.toString() ?? '';
      });
    }

    return OdbcAuditEvent(
      timestampMs: (json['timestamp_ms'] as num?)?.toInt() ?? 0,
      eventType: json['event_type'] as String? ?? 'unknown',
      connectionId: (json['connection_id'] as num?)?.toInt(),
      query: json['query'] as String?,
      metadata: normalizedMetadata,
    );
  }

  final int timestampMs;
  final String eventType;
  final int? connectionId;
  final String? query;
  final Map<String, String> metadata;
}

/// Sync typed wrapper around native audit FFI endpoints.
///
/// Uses [OdbcNative] for transport and exposes parsed model objects for
/// status/events.
class OdbcAuditLogger {
  /// Creates a typed sync audit logger.
  OdbcAuditLogger(this._native);

  final OdbcNative _native;

  /// Enables native audit collection.
  bool enable() => _native.setAuditEnabled(enabled: true);

  /// Disables native audit collection.
  bool disable() => _native.setAuditEnabled(enabled: false);

  /// Clears all in-memory native audit events.
  bool clear() => _native.clearAuditEvents();

  /// Returns parsed audit status, or `null` when unavailable/invalid.
  OdbcAuditStatus? getStatus() {
    final payload = _native.getAuditStatusJson();
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
  List<OdbcAuditEvent> getEvents({int limit = 0}) {
    final payload = _native.getAuditEventsJson(limit: limit);
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

/// Typed status payload for native audit subsystem.
class OdbcAuditStatus {
  /// Creates an [OdbcAuditStatus].
  OdbcAuditStatus({
    required this.enabled,
    required this.eventCount,
  });

  /// Builds an [OdbcAuditStatus] from a decoded JSON map.
  factory OdbcAuditStatus.fromJson(Map<String, Object?> json) {
    return OdbcAuditStatus(
      enabled: json['enabled'] as bool? ?? false,
      eventCount: (json['event_count'] as num?)?.toInt() ?? 0,
    );
  }

  final bool enabled;
  final int eventCount;
}

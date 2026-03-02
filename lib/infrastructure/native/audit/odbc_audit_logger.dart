import 'dart:convert';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';

class OdbcAuditEvent {
  OdbcAuditEvent({
    required this.timestampMs,
    required this.eventType,
    required this.connectionId,
    required this.query,
    required this.metadata,
  });

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

class OdbcAuditLogger {
  OdbcAuditLogger(this._native);

  final OdbcNative _native;

  bool enable() => _native.setAuditEnabled(enabled: true);

  bool disable() => _native.setAuditEnabled(enabled: false);

  bool clear() => _native.clearAuditEvents();

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

class OdbcAuditStatus {
  OdbcAuditStatus({
    required this.enabled,
    required this.eventCount,
  });

  factory OdbcAuditStatus.fromJson(Map<String, Object?> json) {
    return OdbcAuditStatus(
      enabled: json['enabled'] as bool? ?? false,
      eventCount: (json['event_count'] as num?)?.toInt() ?? 0,
    );
  }

  final bool enabled;
  final int eventCount;
}

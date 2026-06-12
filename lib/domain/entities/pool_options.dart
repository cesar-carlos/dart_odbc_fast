import 'dart:convert';

import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile_preset.dart';

/// Optional eviction/timeout knobs for a connection pool created via
/// `odbc_pool_create_with_options` (NEW v3.0).
///
/// Mirror of the Rust `pool::PoolOptions` struct. Every field is `null` by
/// default; the native side falls back to the engine defaults
/// (`connection_timeout = 30s`, no `idle_timeout`, no `max_lifetime`).
class PoolOptions {
  const PoolOptions({
    this.idleTimeout,
    this.maxLifetime,
    this.connectionTimeout,
  });

  factory PoolOptions.fromUsageProfile(OdbcUsageProfile profile) {
    final preset = resolveOdbcUsageProfilePreset(profile);
    return PoolOptions(
      idleTimeout: preset.poolIdleTimeout,
      maxLifetime: preset.poolMaxLifetime,
      connectionTimeout: preset.poolConnectionTimeout,
    );
  }

  /// Connections idle for longer than this are closed by the background
  /// reaper. `null` disables idle eviction.
  final Duration? idleTimeout;

  /// A connection is closed when it exceeds this lifetime (checked on return
  /// to the pool). `null` disables lifetime eviction.
  final Duration? maxLifetime;

  /// Maximum time `acquire` will wait for an available connection.
  /// `null` falls back to the engine default (30 s).
  final Duration? connectionTimeout;

  /// Encode as the JSON shape expected by `odbc_pool_create_with_options`.
  /// Returns an empty string when no fields are set (caller may pass `null`
  /// FFI pointer instead, equivalent meaning).
  String? toJson() {
    // Clamp to 0 so negative Durations do not produce negative u64 values
    // on the Rust side (which would overflow or be treated as "no timeout").
    int msOrZero(Duration d) => d.inMilliseconds.clamp(0, 0x7FFFFFFFFFFFFFFF);
    final map = <String, Object?>{
      if (idleTimeout != null) 'idle_timeout_ms': msOrZero(idleTimeout!),
      if (maxLifetime != null) 'max_lifetime_ms': msOrZero(maxLifetime!),
      if (connectionTimeout != null)
        'connection_timeout_ms': msOrZero(connectionTimeout!),
    };
    if (map.isEmpty) return null;
    return jsonEncode(map);
  }

  /// `true` iff at least one option is set.
  bool get hasAnyOption =>
      idleTimeout != null || maxLifetime != null || connectionTimeout != null;
}

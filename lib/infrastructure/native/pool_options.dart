import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';

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
    final map = <String, Object?>{
      if (idleTimeout != null) 'idle_timeout_ms': idleTimeout!.inMilliseconds,
      if (maxLifetime != null) 'max_lifetime_ms': maxLifetime!.inMilliseconds,
      if (connectionTimeout != null)
        'connection_timeout_ms': connectionTimeout!.inMilliseconds,
    };
    if (map.isEmpty) return null;
    return jsonEncode(map);
  }

  /// `true` iff at least one option is set.
  bool get hasAnyOption =>
      idleTimeout != null || maxLifetime != null || connectionTimeout != null;
}

/// Pure routing used by [OdbcPoolFactory.createPool], testable without FFI.
@visibleForTesting
int createPoolDispatch({
  required bool supportsPoolCreateWithOptions,
  required String connectionString,
  required int maxSize,
  required int Function(String connectionString, int maxSize) poolCreate,
  required int Function(
    String connectionString,
    int maxSize, {
    String? optionsJson,
  }) poolCreateWithOptions,
  PoolOptions? options,
}) {
  if (options == null || !options.hasAnyOption) {
    return poolCreate(connectionString, maxSize);
  }
  if (!supportsPoolCreateWithOptions) {
    return poolCreate(connectionString, maxSize);
  }
  return poolCreateWithOptions(
    connectionString,
    maxSize,
    optionsJson: options.toJson(),
  );
}

/// Typed wrapper for the v3.0 pool-creation FFI with options support.
class OdbcPoolFactory {
  OdbcPoolFactory(this._native);

  final OdbcNative _native;

  /// True when the loaded native library exposes
  /// `odbc_pool_create_with_options`.
  bool get supportsApi => _native.supportsPoolCreateWithOptions;

  /// Create a pool. When [options] is null or has no fields set, falls back
  /// to the legacy `odbc_pool_create` (no options) for maximum compatibility.
  ///
  /// Returns the pool id (>0) on success, `0` on failure (call
  /// `getLastError` for details).
  int createPool(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) {
    return createPoolDispatch(
      supportsPoolCreateWithOptions: supportsApi,
      connectionString: connectionString,
      maxSize: maxSize,
      options: options,
      poolCreate: _native.poolCreate,
      poolCreateWithOptions: _native.poolCreateWithOptions,
    );
  }
}

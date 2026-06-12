import 'package:meta/meta.dart';
import 'package:odbc_fast/domain/entities/pool_options.dart';
import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';

export 'package:odbc_fast/domain/entities/pool_options.dart';

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

  /// True when the loaded native library exposes map pool create with options.
  bool get supportsApi => _native.supportsPoolCreateWithOptions;

  /// Create a pool. When [options] is null or has no fields set, falls back
  /// to the legacy `odbc_pool_create` (no options) for maximum compatibility.
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

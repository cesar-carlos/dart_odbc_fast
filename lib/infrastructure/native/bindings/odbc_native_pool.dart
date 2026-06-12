part of 'odbc_native.dart';

mixin _OdbcNativePool on _OdbcNativeState {
  /// Creates a new connection pool.
  ///
  /// The [connectionString] is used to establish connections in the pool.
  /// The [maxSize] specifies the maximum number of connections in the pool.
  ///
  /// Returns a pool ID on success, 0 on failure.
  int poolCreate(String connectionString, int maxSize) {
    final connStrPtr = connectionString.toNativeUtf8();
    try {
      return _bindings.odbc_pool_create(
        connStrPtr.cast<bindings.Utf8>(),
        maxSize,
      );
    } finally {
      malloc.free(connStrPtr);
    }
  }

  /// Whether the loaded native library exposes the v3.0
  /// `odbc_pool_create_with_options` entry point.
  bool get supportsPoolCreateWithOptions =>
      _bindings.supportsPoolCreateWithOptions;

  /// Creates a pool with explicit eviction/timeout options (v3.0).
  ///
  /// `optionsJson` keys (all optional, in milliseconds):
  /// `idle_timeout_ms`, `max_lifetime_ms`, `connection_timeout_ms`.
  /// Returns 0 on failure or when the FFI is not available.
  int poolCreateWithOptions(
    String connectionString,
    int maxSize, {
    String? optionsJson,
  }) {
    if (!_bindings.supportsPoolCreateWithOptions) return 0;
    final connStrPtr = connectionString.toNativeUtf8();
    final optsPtr = optionsJson?.toNativeUtf8().cast<bindings.Utf8>();
    try {
      return _bindings.odbc_pool_create_with_options(
        connStrPtr.cast<bindings.Utf8>(),
        maxSize,
        optsPtr,
      );
    } finally {
      malloc.free(connStrPtr);
      if (optsPtr != null) {
        malloc.free(optsPtr.cast<Utf8>());
      }
    }
  }

  /// Gets a connection from the pool.
  ///
  /// The [poolId] must be a valid pool identifier.
  /// Returns a connection ID on success, 0 on failure.
  int poolGetConnection(int poolId) {
    return _bindings.odbc_pool_get_connection(poolId);
  }

  /// Releases a connection back to the pool.
  ///
  /// The [connectionId] must be a connection obtained from [poolGetConnection].
  /// Returns true on success, false on failure.
  bool poolReleaseConnection(int connectionId) {
    return _bindings.odbc_pool_release_connection(connectionId) == 0;
  }

  /// Performs a health check on the connection pool.
  ///
  /// The [poolId] must be a valid pool identifier.
  /// Returns true if the pool is healthy, false otherwise.
  bool poolHealthCheck(int poolId) {
    return _bindings.odbc_pool_health_check(poolId) == 1;
  }

  /// Gets the current state of the connection pool.
  ///
  /// The [poolId] must be a valid pool identifier.
  /// Returns a record with pool size and idle count, or null on failure.
  ({int size, int idle})? poolGetState(int poolId) {
    final outSize = malloc<ffi.Uint32>();
    final outIdle = malloc<ffi.Uint32>();
    try {
      final code = _bindings.odbc_pool_get_state(poolId, outSize, outIdle);
      if (code != 0) return null;
      return (size: outSize.value, idle: outIdle.value);
    } finally {
      malloc
        ..free(outSize)
        ..free(outIdle);
    }
  }

  /// Gets pool state as JSON (detailed metrics for monitoring).
  ///
  /// Returns a map with keys: total_connections, idle_connections,
  /// active_connections, max_size, wait_count, wait_time_ms,
  /// max_wait_time_ms, avg_wait_time_ms. Returns null on failure.
  Map<String, dynamic>? poolGetStateJson(int poolId) {
    final data = callWithBuffer(
      (buf, bufLen, outWritten) =>
          _bindings.odbc_pool_get_state_json(poolId, buf, bufLen, outWritten),
      initialSize: 256,
    );
    if (data == null || data.isEmpty) return null;
    try {
      final json = utf8.decode(data);
      return jsonDecode(json) as Map<String, dynamic>;
    } on Object {
      return null;
    }
  }

  /// Resizes the pool by recreating it with [newMaxSize].
  ///
  /// All connections must be released before resize. Returns true on success,
  /// false on failure (invalid pool, connections checked out, or pool creation
  /// failed).
  bool poolSetSize(int poolId, int newMaxSize) {
    return _bindings.odbc_pool_set_size(poolId, newMaxSize) == 0;
  }

  /// Closes the connection pool and releases all connections.
  ///
  /// The [poolId] must be a valid pool identifier.
  /// Returns true on success, false on failure.
  bool poolClose(int poolId) {
    return _bindings.odbc_pool_close(poolId) == 0;
  }
}

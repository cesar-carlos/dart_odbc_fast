part of 'native_odbc_connection.dart';

mixin _NativePool on _NativeOdbcState {
  /// Creates a new connection pool.
  ///
  /// The [connectionString] is used to establish connections in the pool.
  /// The [maxSize] specifies the maximum number of connections in the pool.
  ///
  /// Returns a pool ID on success, 0 on failure.
  int poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) =>
      _captureSync(
        'poolCreate',
        () {
          if (options == null || !options.hasAnyOption) {
            return _native.poolCreate(connectionString, maxSize);
          }
          return _native.poolCreateWithOptions(
            connectionString,
            maxSize,
            optionsJson: options.toJson(),
          );
        },
        failed: (value) => value == 0,
      );

  /// Creates a pool from a pre-encoded native options JSON payload.
  int poolCreateWithOptions(
    String connectionString,
    int maxSize, {
    String? optionsJson,
  }) =>
      _captureSync(
        'poolCreateWithOptions',
        () => _native.poolCreateWithOptions(
          connectionString,
          maxSize,
          optionsJson: optionsJson,
        ),
        failed: (value) => value == 0,
      );

  /// Creates a new connection pool and returns a [ConnectionPool] wrapper.
  ///
  /// The [connectionString] is used to establish connections in the pool.
  /// The [maxSize] specifies the maximum number of connections in the pool.
  ///
  /// Returns a [ConnectionPool] on success, null on failure.
  ConnectionPool? createConnectionPool(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) {
    final poolId = poolCreate(connectionString, maxSize, options: options);
    if (poolId == 0) return null;
    return ConnectionPool(_connection, poolId);
  }

  int poolGetConnection(int poolId) => _captureSync(
        'poolGetConnection',
        () => _native.poolGetConnection(poolId),
        failed: (value) => value == 0,
      );

  bool poolReleaseConnection(int connectionId) => _captureSync(
        'poolReleaseConnection',
        () => _native.poolReleaseConnection(connectionId),
        failed: (value) => !value,
        nativeConnectionId: connectionId,
      );

  bool poolHealthCheck(int poolId) => _captureSync(
        'poolHealthCheck',
        () => _native.poolHealthCheck(poolId),
        failed: (value) => !value,
      );

  ({int size, int idle})? poolGetState(int poolId) =>
      _native.poolGetState(poolId);

  /// Returns pool state telemetry payload as JSON, or null on failure.
  Map<String, dynamic>? poolGetStateJson(int poolId) =>
      _native.poolGetStateJson(poolId);

  bool poolSetSize(int poolId, int newMaxSize) => _captureSync(
        'poolSetSize',
        () => _native.poolSetSize(poolId, newMaxSize),
        failed: (value) => !value,
      );

  bool poolClose(int poolId) => _captureSync(
        'poolClose',
        () => _native.poolClose(poolId),
        failed: (value) => !value,
      );

  /// Performs a bulk insert operation.
  ///
  /// Inserts multiple rows into [table] using the specified [columns].
  /// The [dataBuffer] contains the data as a binary buffer created by
  /// [BulkInsertBuilder.build()].
  ///
  /// The [rowCount] specifies how many rows are in [dataBuffer].
  /// Returns the number of rows inserted on success, 0 on failure.
  int bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) =>
      _captureSync(
        'bulkInsertArray',
        () => _native.bulkInsertArray(
          connectionId,
          table,
          columns,
          dataBuffer,
          rowCount,
        ),
        failed: (value) => value < 0,
        nativeConnectionId: connectionId,
      );

  /// Performs parallel bulk insert through [poolId].
  ///
  /// Uses pool-managed parallel workers in Rust. Returns rows inserted on
  /// success, or negative value on failure.
  int bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int parallelism,
  ) =>
      _captureSync(
        'bulkInsertParallel',
        () => _native.bulkInsertParallel(
          poolId,
          table,
          columns,
          dataBuffer,
          parallelism,
        ),
        failed: (value) => value < 0,
      );
}
